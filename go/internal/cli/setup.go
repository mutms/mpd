package cli

import (
	"context"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"
	"time"

	"github.com/mutms/mpd/go/internal/cert"
	"github.com/mutms/mpd/go/internal/current"
	"github.com/mutms/mpd/go/internal/db"
	"github.com/mutms/mpd/go/internal/dnsmasq"
	"github.com/mutms/mpd/go/internal/hooks"
	"github.com/mutms/mpd/go/internal/net"
	"github.com/mutms/mpd/go/internal/podman"
	"github.com/mutms/mpd/go/internal/project"
	"github.com/mutms/mpd/go/internal/runtime"
	"github.com/mutms/mpd/go/internal/service"
	"github.com/mutms/mpd/go/internal/srv"
	"github.com/mutms/mpd/go/internal/state"
	"github.com/mutms/mpd/go/internal/ui"
	"github.com/mutms/mpd/go/internal/vm"
)

// Network is the podman network every mpd container attaches to.
const Network = "mpd-internal"

// BaseImagePull is fetched during setup so the first project create does
// not also pay for a several-hundred-megabyte download.
const BaseImagePull = "docker.io/library/postgres:17"

// Setup brings a bootstrapped VM to a working mpd install.
//
// Idempotent from end to end, and that is the property to preserve when
// changing it: `--vm-setup` is the repair command. A developer whose VM has
// drifted — containers removed by hand, state wiped, CA replaced, VM ID
// changed — runs it again, and every step either converges or says
// precisely what it cannot fix. No step may assume it is running for the
// first time.
//
// Ordering is not arbitrary:
//
//   - identity (platform.env) before anything that composes a name or an
//     address, since all of them derive from the VM ID;
//   - the CA before the service containers, whose rebuild is keyed on
//     its fingerprint;
//   - the /srv mount before anything touching the data volume, since that
//     is what makes the path exist on the VM;
//   - dnsmasq and the portal after both, since they mount the CA-derived
//     certificates.
func Setup(ctx context.Context, out io.Writer) error {
	// The one verb that announces itself: its transcript is long enough
	// that a scrollback needs a mark for where it began.
	fmt.Fprintf(out, "\n\033[1mmpd --vm-setup\033[0m\n\n")

	if _, err := vm.AssetsPath(); err != nil {
		return err
	}
	ui.OK(out, "Execution environment: %s", vm.Label)

	if err := preflight(ctx, out); err != nil {
		return err
	}

	ui.Step(out, "Conf directory")
	if err := vm.EnsureDir(vm.ConfDir, 0o755); err != nil {
		return err
	}
	ui.OK(out, "Ensured %s/", vm.ConfDir)

	n, identity, err := setupIdentity(ctx, out)
	if err != nil {
		return err
	}

	ui.Step(out, "VM-local SSH key")
	if err := vm.EnsureSSHKey(ctx, out); err != nil {
		return err
	}

	ui.Step(out, "Configuration")
	s := state.New()
	user := vm.DetectIdentity()
	if err := s.SaveConfig(state.Config{UID: user.UID, User: user.User}); err != nil {
		return err
	}
	ui.OK(out, "user=%s  uid=%s", user.User, user.UID)

	caChanged, err := setupCertificates(ctx, out, n)
	if err != nil {
		return err
	}

	p := podman.New()
	if err := setupHostTrustAndDNS(ctx, out, n); err != nil {
		return err
	}
	if err := setupNetworkAndVolume(ctx, out, p, n); err != nil {
		return err
	}

	// Before anything touches /srv: this is what makes the path exist on
	// the VM at all, and it must resolve to the same tree containers see.
	ui.Step(out, "Data volume mounted at /srv")
	source, ok := p.VolumeMountpoint(ctx, vm.DataVolume)
	if !ok {
		return fmt.Errorf("Could not read the mountpoint of volume '%s'.", vm.DataVolume)
	}
	if err := vm.MountDataVolume(ctx, out, source); err != nil {
		return err
	}

	// The volume root is root-owned, so this is what makes the tree
	// writable by mpd at all.
	ui.Step(out, "Data volume layout")
	if err := srv.EnsureLayout(ctx, user.UID); err != nil {
		return err
	}
	ui.OK(out, "%s/{projects,data,meta,dbs,backups,extra} ready.", srv.Dir)

	ui.Step(out, "mudev toolchain")
	if err := vm.EnsureMudev(ctx, out); err != nil {
		return err
	}

	ui.Step(out, "VM metadata (/srv/meta/vm.json)")
	if err := VMMeta(ctx, p, n, state.Dir); err != nil {
		return err
	}
	ui.OK(out, "zone %s, subnet %s", n.Zone(), n.Subnet())

	if err := setupStateDirectories(ctx, out); err != nil {
		return err
	}

	m := dnsmasq.New(state.Dir, n, p)
	caFingerprint := vm.Fingerprint(ctx, vm.CACertPath)
	if err := service.SetupDnsmasq(ctx, out, p, n, m, caFingerprint, identity.VMIP); err != nil {
		return err
	}
	if err := service.SetupPortal(ctx, out, p, n, caFingerprint, user.User); err != nil {
		return err
	}

	ui.Step(out, "DNS resolution")
	verifyDNS(ctx, out, n, p)

	ui.Step(out, "Shell completion for mpd")
	InstallCompletion(out)

	ui.Step(out, "Installing login banner (motd)")
	if err := vm.InstallLoginBanner(ctx, out, n.Zone()); err != nil {
		return err
	}

	if err := reconcileCaches(ctx, out, p, s, n, m, identity.VMIP, user.UID, caChanged); err != nil {
		return err
	}

	// Adminer is best-effort: it is a convenience UI, and a VM without
	// it still runs every project.
	if err := service.SetupAdminer(ctx, out, p, n); err != nil {
		ui.Warn(out, "%v", err)
	}

	_, _ = p.PullQuiet(ctx, BaseImagePull)

	ui.Step(out, "Installing shutdown unit")
	if err := vm.InstallShutdownUnit(ctx, user.User); err != nil {
		return err
	}
	ui.OK(out, "~/.config/systemd/user/mpd.service installed and enabled.")

	// Silent in the happy path; warns only when a hook directory is
	// orphaned, misfiled, or newly stale after an event revision bump.
	hooks.Diagnose(out, state.Dir)

	if err := current.NewObserver(n.VMID(), p).Refresh(ctx, state.Dir, s, time.Now()); err != nil {
		return err
	}

	// Deliberately terse: anything about "what to do next" belongs to
	// whatever orchestration called us — `mpd-virt setup` for a managed
	// VM, sandbox/provision.sh for the sandbox.
	fmt.Fprintf(out, "\n\033[1;32m✓ mpd --vm-setup complete.\033[0m\n")
	return nil
}

// preflight refuses to run on a host mpd does not support, or one where
// bootstrap has not finished. Both produce failures far from their cause
// if allowed through.
func preflight(ctx context.Context, out io.Writer) error {
	if err := vm.RequireSupportedHost(); err != nil {
		return err
	}
	if err := vm.RequireBootstrapCompleted(); err != nil {
		return err
	}
	if err := vm.RequireSystemdResolvedActive(ctx, out); err != nil {
		return err
	}
	ui.OK(out, "Podman runs natively — no machine needed.")
	return nil
}

// setupIdentity refreshes the VM ID from the hostname and returns the
// addressing derived from it.
//
// Re-derived on every run rather than trusted from the file: the
// hostname is what the hypervisor-side bootstrap set, so a VM cloned to
// a new identity converges here. A hand-edited MPD_VM_ID therefore
// survives only until the next `--vm-setup`, which is the documented
// behaviour.
//
// This is also why net.Load runs here rather than at process start: a VM
// whose platform.env holds a broken ID must still be repairable by
// `mpd --vm-setup`, and a preflight resolve would refuse before we could
// fix it.
func setupIdentity(ctx context.Context, out io.Writer) (net.Net, vm.PlatformIdentity, error) {
	ui.Step(out, "Platform identity")
	identity, err := vm.LoadPlatform()
	if err != nil {
		return net.Net{}, identity, err
	}
	if derived := vm.DeriveVMID(); derived != identity.VMID {
		identity.VMID = derived
		if err := vm.WritePlatform(identity); err != nil {
			return net.Net{}, identity, err
		}
	}
	ui.OK(out, "Platform: %s, VM IP: %s, VM ID: %s",
		identity.Platform, dashIfEmpty(identity.VMIP), dashIfEmpty(identity.VMID))

	n, err := net.Load(vm.PlatformEnvPath)
	return n, identity, err
}

func dashIfEmpty(s string) string {
	if s == "" {
		return "—"
	}
	return s
}

// setupCertificates ensures the CA and the service certificate exist and
// are current, reporting whether the CA changed.
//
// A changed CA invalidates every certificate it signed, so the answer
// propagates: service containers are rebuilt on it, and project certs
// are reissued.
func setupCertificates(ctx context.Context, out io.Writer, n net.Net) (bool, error) {
	ui.Step(out, "Root CA certificate")
	// 0700 on both: one holds the CA private key, the other the openssl
	// scratch files that briefly contain key material.
	for _, dir := range []string{vm.CARootDir, vm.TempDir} {
		if err := vm.EnsureDir(dir, 0o700); err != nil {
			return false, err
		}
	}

	if _, err := os.Stat(vm.CACertPath); err != nil {
		if err := cert.GenerateCA(ctx, vm.CAKeyPath, vm.CACertPath); err != nil {
			return false, err
		}
		ui.OK(out, "CA certificate generated in %s", vm.CACertPath)
	} else {
		ui.OK(out, "CA already exists in %s", vm.CACertPath)
	}
	for _, required := range []string{vm.CACertPath, vm.CAKeyPath} {
		if info, err := os.Stat(required); err != nil || info.IsDir() {
			return false, fmt.Errorf("Root CA material missing or invalid: %s", required)
		}
	}

	ui.Step(out, "Services certificate")
	var (
		certPath        = vm.ServiceDir + "/cert.pem"
		keyPath         = vm.ServiceDir + "/key.pem"
		fingerprintPath = vm.ServiceDir + "/rootCA.fingerprint"
		sansPath        = vm.ServiceDir + "/cert.sans"
	)
	fingerprint := vm.Fingerprint(ctx, vm.CACertPath)
	caChanged := readTrimmed(fingerprintPath) != fingerprint

	// SAN drift: the service cert covers exactly the zone apex, and the
	// zone changes when the VM's ID does. A cert issued for a previous
	// zone still verifies against the CA, so nothing else here would
	// notice — and every HTTPS hit on the portal would fail hostname
	// verification. Same signature-file pattern the project certs use.
	sans := []string{n.Zone()}
	signature := strings.Join(sans, "\n")
	sansChanged := readTrimmed(sansPath) != signature

	if !exists(certPath) || !exists(keyPath) || caChanged || sansChanged {
		if err := vm.EnsureDir(vm.ServiceDir, 0o700); err != nil {
			return false, err
		}
		if err := cert.Generate(ctx, sans, certPath, keyPath); err != nil {
			return false, err
		}
		if err := os.WriteFile(fingerprintPath, []byte(fingerprint), 0o644); err != nil {
			return false, err
		}
		if err := os.WriteFile(sansPath, []byte(signature), 0o644); err != nil {
			return false, err
		}
		ui.OK(out, "Services certificate generated in %s for %s", vm.ServiceDir, strings.Join(sans, ", "))
	} else {
		ui.OK(out, "Services cert already exists in %s", vm.ServiceDir)
	}
	return caChanged, nil
}

// setupHostTrustAndDNS covers the four places on the VM that have to
// learn about mpd: three trust stores and the resolver.
func setupHostTrustAndDNS(ctx context.Context, out io.Writer, n net.Net) error {
	ui.Step(out, "Root Certificate Authority for %s in system trust store", net.RootDomain)
	vm.TrustCA(ctx, out, vm.CACertPath)

	ui.Step(out, "Trust mpd CA in user's NSS DB (Chromium)")
	if err := vm.EnsureCAInUserNSSDB(ctx, out, vm.CACertPath); err != nil {
		return err
	}

	ui.Step(out, "Trust mpd CA in Firefox (enterprise policy)")
	vm.InstallFirefoxPolicy(ctx, out, vm.CACertPath, n.Zone())

	ui.Step(out, "DNS resolver for %s", net.RootDomain)
	return vm.ConfigureDNSResolver(ctx, out, net.RootDomain, n.IP(net.HostDnsmasq))
}

// setupNetworkAndVolume creates the podman network and the data volume.
//
// The network check is a refusal, not a repair: a podman network's
// subnet is fixed at creation, so a network created under a different VM
// ID keeps handing out addresses from the OLD subnet while mpd composes
// DNS records and certificate SANs from the new one. Every name would
// resolve to an address nothing listens on. Reporting success on that is
// worse than stopping, so this prints the migration and refuses.
func setupNetworkAndVolume(ctx context.Context, out io.Writer, p *podman.Client, n net.Net) error {
	ui.Step(out, "Podman network")
	if p.NetworkExists(ctx, Network) {
		actual := p.NetworkSubnet(ctx, Network)
		if actual != "" && actual != n.Subnet() {
			return fmt.Errorf(`Podman network '%s' is on %s, but this VM's subnet is %s.

A network's subnet cannot be changed in place. This VM predates per-VM addressing (or its MPD_VM_ID changed). Either recreate the VM, or migrate in place — destroys containers, keeps the data volume:

    sudo podman rm -af
    sudo podman network rm %s
    mpd --vm-setup

Then recreate runtimes and DB containers; /srv/ (projects, data, databases) is on the data volume and survives. No reboot needed — `+
				"`podman rm -af`"+` stops the containers, and `+"`mpd --vm-setup`"+` rebuilds the network, records, and certs in place.`,
				Network, actual, n.Subnet(), Network)
		}
		ui.OK(out, "Network '%s' already exists (%s).", Network, n.Subnet())
	} else {
		if code, err := p.NetworkCreate(ctx, Network, n.Subnet(),
			[]string{n.IP(net.HostDnsmasq)}); err != nil || code != 0 {
			return fmt.Errorf("Failed to create Podman network '%s'.", Network)
		}
		ui.OK(out, "Network '%s' created (%s).", Network, n.Subnet())
	}

	ui.Step(out, "Data volume")
	if p.VolumeExists(ctx, vm.DataVolume) {
		ui.OK(out, "Volume '%s' already exists.", vm.DataVolume)
		return nil
	}
	if code, err := p.VolumeCreate(ctx, vm.DataVolume); err != nil || code != 0 {
		return fmt.Errorf("Failed to create data volume '%s'.", vm.DataVolume)
	}
	ui.OK(out, "Volume '%s' created.", vm.DataVolume)
	return nil
}

// setupStateDirectories creates the directories and seed files mpd's own
// state lives in, plus the two user-owned override slots.
func setupStateDirectories(ctx context.Context, out io.Writer) error {
	// Created empty, and that is the point: it is the bind-mount source
	// for every runtime, so it must exist, and its presence tells the
	// user where dotfile overrides go. bootstrap.sh skips the overlay
	// while it stays empty.
	ui.Step(out, "Skel override directory (%s/)", vm.SkelDir)
	if err := os.MkdirAll(vm.SkelDir, 0o755); err != nil {
		return err
	}
	ui.OK(out, "%s/ ready.", vm.SkelDir)

	ui.Step(out, "mpd data directories")
	if err := os.MkdirAll(filepath.Join(state.Dir, "runtimes"), 0o755); err != nil {
		return err
	}
	// Seeded rather than left absent so every reader — including the
	// portal, which cannot run mpd — finds a well-formed empty document.
	for name, empty := range map[string]string{
		"projects.json":  `{"projects":[]}`,
		"databases.json": `{"databases":[]}`,
	} {
		path := filepath.Join(state.Dir, name)
		if !exists(path) {
			if err := os.WriteFile(path, []byte(empty), 0o644); err != nil {
				return err
			}
		}
	}
	ui.OK(out, "%s/ ready.", state.Dir)

	// Copied from the template once and never overwritten: it is the
	// developer's file after that.
	ui.Step(out, "mpd-vm.env defaults")
	if err := os.MkdirAll(vm.EnvDir, 0o755); err != nil {
		return err
	}
	target := filepath.Join(vm.EnvDir, "mpd-vm.env")
	if exists(target) {
		ui.OK(out, "%s already exists — edit to set your defaults.", target)
		return nil
	}
	source := filepath.Join(vm.AssetsDir, "templates", "mpd-vm.env")
	data, err := os.ReadFile(source)
	if err != nil {
		ui.Note(out, "Warning: template not found at %s", source)
		return nil
	}
	if err := os.WriteFile(target, data, 0o644); err != nil {
		return err
	}
	ui.OK(out, "%s created — edit to set your defaults.", target)
	return nil
}

// reconcileCaches rebuilds every derived view from ground truth: the
// data volume for projects, podman for runtimes and databases.
//
// This is the half of setup that repairs drift, so it runs on every
// invocation and not only on a fresh VM.
func reconcileCaches(ctx context.Context, out io.Writer, p *podman.Client, s state.Store,
	n net.Net, m dnsmasq.Manager, vmIP, uid string, caChanged bool) error {

	ui.Step(out, "Rescanning data volume")
	if err := project.Rescan(ctx, out, s); err != nil {
		return err
	}

	ui.Step(out, "Probing existing runtime containers")
	if err := runtime.RebuildStateCache(ctx, out, p, s); err != nil {
		return err
	}

	ui.Step(out, "Probing existing database containers")
	if err := db.RebuildStateCache(ctx, p, s); err != nil {
		return err
	}
	if count := len(s.Databases()); count == 0 {
		ui.OK(out, "No databases found.")
	} else {
		ui.OK(out, "Database cache rebuilt (%d database(s) found).", count)
	}
	if err := service.EnsureDnsmasqReady(ctx, out, p, n, m, vmIP, false); err != nil {
		return err
	}

	if !caChanged {
		return nil
	}
	ui.Step(out, "Reconciling TLS certificates")
	targets := make([]runtime.CertTarget, 0)
	byName := map[string][]state.ProjectURL{}
	for _, pr := range s.Projects() {
		if pr.Name == "" {
			continue
		}
		targets = append(targets, runtime.CertTarget{Name: pr.Name, Host: n.Host(pr.Name)})
		byName[pr.Name] = pr.URLs
	}
	runtime.ReconcileCertificates(ctx, out, p, targets, func(name string) error {
		return project.EnsureCert(ctx, out, name, byName[name], n, p, uid)
	})
	return nil
}

func readTrimmed(path string) string {
	data, err := os.ReadFile(path)
	if err != nil {
		return ""
	}
	return strings.TrimSpace(string(data))
}

func exists(path string) bool {
	_, err := os.Stat(path)
	return err == nil
}
