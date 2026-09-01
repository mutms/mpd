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
	"github.com/mutms/mpd/go/internal/exec"
	"github.com/mutms/mpd/go/internal/hooks"
	"github.com/mutms/mpd/go/internal/net"
	"github.com/mutms/mpd/go/internal/podman"
	"github.com/mutms/mpd/go/internal/project"
	"github.com/mutms/mpd/go/internal/service"
	"github.com/mutms/mpd/go/internal/srv"
	"github.com/mutms/mpd/go/internal/state"
	"github.com/mutms/mpd/go/internal/ui"
	"github.com/mutms/mpd/go/internal/vm"
	"github.com/mutms/mpd/go/internal/web"
)

// Network is the podman network every mpd container attaches to, and
// NetworkInterface is the host bridge it hangs off. The bridge is named
// explicitly because the resolver binds the gateway by interface name.
// Never rename it "mpd0": older VMs still bring up a WireGuard mpd0 at
// boot, and netavark then refuses to create the network.
const (
	Network          = "mpd-internal"
	NetworkInterface = "mpdbr0"
)

// Setup brings a bootstrapped VM to a working mpd install. It is the
// repair command: idempotent end to end, and no step may assume it runs
// for the first time. Ordering is a dependency chain — identity before
// anything that composes a name, the CA before the service containers
// keyed on its fingerprint, the /srv mount before anything touching the
// volume, dnsmasq and the portal after both.
func Setup(ctx context.Context, out io.Writer) error {
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

	n, vmIP, err := setupIdentity(ctx, out)
	if err != nil {
		return err
	}

	ui.Step(out, "SSH directory")
	if err := vm.EnsureSSHDir(out); err != nil {
		return err
	}

	ui.Step(out, "Configuration")
	s := state.New()
	user := vm.DetectIdentity()
	if err := s.SaveConfig(state.Config{UID: user.UID, User: user.User}); err != nil {
		return err
	}
	ui.OK(out, "user=%s  uid=%s", user.User, user.UID)

	ui.Step(out, "Developer home files")
	if err := vm.EnsureHome(out); err != nil {
		return err
	}

	certs, err := setupCertificates(ctx, out, n)
	if err != nil {
		return err
	}

	p := podman.New()
	if err := setupHostTrust(ctx, out, n); err != nil {
		return err
	}
	if err := refuseLegacyRuntime(ctx, out, p, n); err != nil {
		return err
	}

	if err := setupNetworkAndVolume(ctx, out, p, n); err != nil {
		return err
	}

	// Create the static bridge after the network is registered but
	// before dnsmasq and caddy bind the gateway, so it exists at boot
	// and netavark only attaches containers to it. wg0 gives the host
	// an encrypted path to the subnet (peer added by mpd-virt).
	if err := vm.EnsureBridge(ctx, out, n.Gateway()+"/24", n.IP(net.HostProjects)+"/24"); err != nil {
		return err
	}
	if err := vm.EnsureWireGuard(ctx, out, n.Octet()); err != nil {
		return err
	}
	// Seal the container subnet from the LAN: only the bridge and wg0
	// may route into it. Container outbound NAT is untouched.
	if err := vm.EnsureFirewall(ctx, out, n.Subnet()); err != nil {
		return err
	}

	// Must run before anything touches /srv — this makes the path exist
	// on the VM, resolving to the same tree containers see.
	ui.Step(out, "Data volume mounted at /srv")
	source, ok := p.VolumeMountpoint(ctx, vm.DataVolume)
	if !ok {
		return fmt.Errorf("Could not read the mountpoint of volume '%s'.", vm.DataVolume)
	}
	if err := vm.MountDataVolume(ctx, out, source); err != nil {
		return err
	}

	// The volume root is root-owned; this makes the tree writable by mpd.
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

	// Records first, then the resolver: dnsmasq reads /etc/hosts on
	// start, and cloud-init is told not to wipe the block before the
	// block is relied on.
	ui.Step(out, "DNS records in /etc/hosts")
	if err := vm.DisableCloudInitHosts(ctx, out); err != nil {
		return err
	}
	m := dnsmasq.New(n, p, s)
	if err := PublishDNS(ctx, out, m, n, s, true); err != nil {
		return err
	}

	ui.Step(out, "DNS resolver (dnsmasq)")
	if err := vm.ConfigureDnsmasq(ctx, out, n.Gateway(), p.NetworkInterface(ctx, Network)); err != nil {
		return err
	}

	ui.Step(out, "Shell completion for mpd")
	InstallCompletion(out)

	ui.Step(out, "Git hooks (disabled on the VM)")
	if err := vm.DisableGitHooks(ctx, out); err != nil {
		return err
	}

	ui.Step(out, "Installing login banner (motd)")
	if err := vm.InstallLoginBanner(ctx, out, n.Zone()); err != nil {
		return err
	}

	if err := reconcileCaches(ctx, out, p, s, n, m, vmIP, user.UID, certs.CAChanged); err != nil {
		return err
	}

	// Must run before the dev stack install: apt resolves
	// through this resolver, and a resolver not answering yet fails the
	// build minutes in with the cause several screens up.
	ui.Step(out, "DNS resolution")
	if err := vm.EnsureDnsmasqResolving(ctx, out, n.Gateway(), n.Zone()); err != nil {
		return err
	}
	// Fatal, unlike verifyDNS's report: without an upstream the stack
	// build below cannot install a single package.
	if err := vm.RequireDNSUpstream(ctx, out, n.Gateway()); err != nil {
		return err
	}
	verifyDNS(ctx, out, n)

	ui.Step(out, "Dev stack (PHP, Composer, Node)")
	if err := configureStack(ctx, out); err != nil {
		return err
	}

	// Converge whatever the developer marked autostart; a service a
	// project needs starts on demand from that project, not here.
	ui.Step(out, "Extra services")
	if err := ReconcileServices(ctx, out, p, s, n); err != nil {
		ui.Warn(out, "%v", err)
	}
	if installed := s.Services(); len(installed) == 0 {
		ui.OK(out, "none installed — a project's MPD_REQUIRE_SERVICES starts what it needs, or mpd --service-start=%s", strings.Join(service.Names(), "|"))
	}

	ui.Step(out, "Status web server (mpd --web)")
	if err := vm.InstallWebUnit(ctx); err != nil {
		return err
	}
	// Restarted on every run: after `make install` a server still
	// running the previous binary would serve stale templates.
	ui.OK(out, "%s restarted (listening on %s).", vm.WebUnitName, web.Addr)

	ui.Step(out, "Apex TLS frontdoor (caddy)")
	// This caddy serves only the zone apex, on the gateway. Project
	// vhosts belong to the project frontdoor below, on its own address,
	// so project traffic never reaches the infra ports.
	sites := []vm.CaddySite{
		{Host: n.Zone(), Upstream: web.Addr},
	}
	if err := vm.ConfigureCaddy(ctx, out, user.User, n.Gateway(),
		vm.ServiceDir+"/cert.pem", vm.ServiceDir+"/key.pem", sites,
		certs.ServiceCertChanged); err != nil {
		return err
	}

	ui.Step(out, "Project TLS frontdoor (%s)", vm.ProjectCaddyUnitName)
	if err := vm.InstallProjectCaddyUnit(ctx, user.User, n.IP(net.HostProjects)); err != nil {
		return err
	}
	ui.OK(out, "project vhosts served on %s:443.", n.IP(net.HostProjects))

	ui.Step(out, "Installing shutdown unit")
	if err := vm.InstallShutdownUnit(ctx, user.User); err != nil {
		return err
	}
	ui.OK(out, "~/.config/systemd/user/mpd.service installed and enabled.")

	// Last: the event means "the VM is ready".
	ui.Step(out, "Setup hooks (mpd-post-setup)")
	postSetup := hooks.MpdPostSetup(ctx, p)
	if err := hooks.Fire(ctx, out, postSetup, "vm-setup", p); err != nil {
		ui.Warn(out, "%v", err)
	}

	// Silent in the happy path; warns on orphaned or stale hook dirs.
	hooks.Diagnose(out, state.Dir)

	if err := current.NewObserver(n.VMID(), p).Refresh(ctx, state.Dir, s, time.Now()); err != nil {
		return err
	}

	// Terse: "what to do next" belongs to the calling orchestration.
	fmt.Fprintf(out, "\n\033[1;32m✓ mpd --vm-setup complete.\033[0m\n")
	return nil
}

// preflight refuses an unsupported host or an unfinished bootstrap;
// both otherwise fail far from their cause.
func preflight(ctx context.Context, out io.Writer) error {
	if err := vm.RequireSupportedHost(); err != nil {
		return err
	}
	if err := vm.RequirePackages(); err != nil {
		return err
	}
	// Must precede podman: an Apple container has /proc/sys read-only,
	// which fails every podman sysctl write. No-op on a real VM.
	if err := vm.EnsureProcSysWritable(ctx, out); err != nil {
		return err
	}
	if err := vm.QuietConsole(ctx, out); err != nil {
		return err
	}
	return vm.EnablePodmanRestart(ctx, out)
}

// setupIdentity derives the VM's addressing from its hostname
// (mpd-<NNN>, the single source of truth) and reads its LAN IP off the
// interface; the IP is empty on a DHCP-less box.
func setupIdentity(ctx context.Context, out io.Writer) (net.Net, string, error) {
	ui.Step(out, "Platform identity")
	n, err := net.Current()
	if err != nil {
		return net.Net{}, "", err
	}
	vmIP := vm.PrimaryIP()
	ui.OK(out, "VM ID: %s, VM IP: %s", n.VMID(), dashIfEmpty(vmIP))
	return n, vmIP, nil
}

func dashIfEmpty(s string) string {
	if s == "" {
		return "—"
	}
	return s
}

// certState reports what setupCertificates changed.
type certState struct {
	// CAChanged is true when the CA that signs leaves moved; every
	// derived certificate is then reissued.
	CAChanged bool
	// ServiceCertChanged is true when the certificate caddy serves was
	// rewritten. Tracked separately: caddy holds the certificate in
	// memory and a reissue leaves the Caddyfile byte-identical, so
	// without this a new leaf would never be picked up.
	ServiceCertChanged bool
}

// setupCertificates ensures the CA and the service certificate exist and
// are current, reporting what it changed.
func setupCertificates(ctx context.Context, out io.Writer, n net.Net) (certState, error) {
	ui.Step(out, "Root CA certificate")
	// 0700 on both: they hold key material.
	for _, dir := range []string{vm.CARootDir, vm.TempDir} {
		if err := vm.EnsureDir(dir, 0o700); err != nil {
			return certState{}, err
		}
	}

	// Which CA this VM signs with depends on provisioning; see
	// cert.ResolveSigner. No CA material means a VM set up without
	// mpd-virt: generate a self-signed CA that is its own anchor.
	signer, ok := cert.ResolveSigner()
	if !ok {
		if err := cert.GenerateCA(ctx, vm.SigningKeyPath, vm.SigningCertPath); err != nil {
			return certState{}, err
		}
		if err := copyFile(vm.SigningCertPath, vm.CACertPath, 0o644); err != nil {
			return certState{}, err
		}
		if signer, ok = cert.ResolveSigner(); !ok {
			return certState{}, fmt.Errorf("Root CA material missing or invalid: %s", vm.CARootDir)
		}
		ui.OK(out, "CA certificate generated in %s", vm.CACertPath)
	} else if signer.Chain {
		ui.OK(out, "Signing with %s, anchored on %s", signer.CertPath, vm.CACertPath)
	} else {
		ui.OK(out, "CA already exists in %s", vm.CACertPath)
	}

	ui.Step(out, "Services certificate")
	var (
		certPath        = vm.ServiceDir + "/cert.pem"
		keyPath         = vm.ServiceDir + "/key.pem"
		fingerprintPath = vm.ServiceDir + "/rootCA.fingerprint"
		sansPath        = vm.ServiceDir + "/cert.sans"
	)
	// Fingerprint the signer, not the anchor: a per-zone intermediate
	// can move while the anchor stays put, and fingerprinting the anchor
	// would then report "nothing changed" for invalidated leaves.
	fingerprint := vm.Fingerprint(ctx, signer.CertPath)
	caChanged := readTrimmed(fingerprintPath) != fingerprint

	// SAN drift: the zone changes when the VM's ID does, and a cert for
	// the old zone still verifies against the CA — only hostname
	// verification would catch it. Just the apex: the portal is the only
	// TLS the VM's own caddy terminates.
	sans := []string{n.Zone()}
	signature := strings.Join(sans, "\n")
	sansChanged := readTrimmed(sansPath) != signature

	state := certState{CAChanged: caChanged}
	if !exists(certPath) || !exists(keyPath) || caChanged || sansChanged {
		if err := vm.EnsureDir(vm.ServiceDir, 0o700); err != nil {
			return certState{}, err
		}
		if err := cert.Generate(ctx, sans, certPath, keyPath); err != nil {
			return certState{}, err
		}
		if err := os.WriteFile(fingerprintPath, []byte(fingerprint), 0o644); err != nil {
			return certState{}, err
		}
		if err := os.WriteFile(sansPath, []byte(signature), 0o644); err != nil {
			return certState{}, err
		}
		state.ServiceCertChanged = true
		ui.OK(out, "Services certificate generated in %s for %s", vm.ServiceDir, strings.Join(sans, ", "))
	} else {
		ui.OK(out, "Services cert already exists in %s", vm.ServiceDir)
	}
	return state, nil
}

// setupHostTrust covers the three trust stores on the VM that must
// learn about mpd's CA.
func setupHostTrust(ctx context.Context, out io.Writer, n net.Net) error {
	ui.Step(out, "Root Certificate Authority for %s in system trust store", net.RootDomain)
	vm.TrustCA(ctx, out, vm.CACertPath)

	ui.Step(out, "Trust mpd CA in user's NSS DB (Chromium)")
	if err := vm.EnsureCAInUserNSSDB(ctx, out, vm.CACertPath); err != nil {
		return err
	}

	ui.Step(out, "Trust mpd CA in Firefox (enterprise policy)")
	vm.InstallFirefoxPolicy(ctx, out, vm.CACertPath, n.Zone())
	return nil
}

// setupNetworkAndVolume creates the podman network and the data volume.
// The network checks are refusals, not repairs: neither the subnet nor
// the dns_enabled flag can be changed in place, so the honest move is
// to name the migration (see networkMismatch).
func setupNetworkAndVolume(ctx context.Context, out io.Writer, p *podman.Client, n net.Net) error {
	ui.Step(out, "Podman network")
	if p.NetworkExists(ctx, Network) {
		if reason := networkMismatch(ctx, p, n); reason != "" {
			return fmt.Errorf(`Podman network '%s' %s

That cannot be changed in place. Migrate — destroys containers, keeps the data volume:

    sudo podman rm -af
    sudo podman network rm %s
    mpd --vm-setup

Then recreate the DB containers; /srv/ (projects, data, databases) is on the data volume and survives. No reboot needed — `+
				"`podman rm -af`"+` stops the containers, and `+"`mpd --vm-setup`"+` rebuilds the network, records, and certs in place.`,
				Network, reason, Network)
		}
		ui.OK(out, "Network '%s' already exists (%s).", Network, n.Subnet())
	} else {
		if code, err := p.NetworkCreate(ctx, Network, NetworkInterface, n.Subnet(), n.AllocRange()); err != nil || code != 0 {
			return fmt.Errorf("Failed to create Podman network '%s'.", Network)
		}
		ui.OK(out, "Network '%s' created (%s, podman DNS off).", Network, n.Subnet())
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

// networkMismatch describes what is wrong with the existing network, or
// "" when it is usable. The text completes a sentence starting with the
// network's name.
func networkMismatch(ctx context.Context, p *podman.Client, n net.Net) string {
	if actual := p.NetworkSubnet(ctx, Network); actual != "" && actual != n.Subnet() {
		return fmt.Sprintf("is on %s, but this VM's subnet is %s.\n"+
			"This VM predates per-VM addressing, or its MPD_VM_ID changed.", actual, n.Subnet())
	}
	if p.NetworkDNSEnabled(ctx, Network) {
		return "was created with podman's DNS enabled.\n" +
			"aardvark-dns holds port 53 on " + n.Gateway() + ", where mpd's resolver listens."
	}
	return ""
}

// setupStateDirectories creates the directories and seed files mpd's own
// state lives in, plus the two user-owned override slots.
func setupStateDirectories(ctx context.Context, out io.Writer) error {
	ui.Step(out, "mpd data directories")
	if err := os.MkdirAll(state.Dir, 0o755); err != nil {
		return err
	}
	// Seeded so every reader — including the portal, which cannot run
	// mpd — finds a well-formed empty document.
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

	// The env dir must exist so mpd-virt has somewhere to push vm.env.
	// Nothing is seeded — there is no shipped template.
	ui.Step(out, "env dir")
	if err := os.MkdirAll(vm.EnvDir, 0o755); err != nil {
		return err
	}
	ui.OK(out, "%s/ ready.", vm.EnvDir)
	return nil
}

// reconcileCaches rebuilds every derived view from ground truth: the
// data volume for projects, podman for databases. It runs
// on every invocation to repair drift.
func reconcileCaches(ctx context.Context, out io.Writer, p *podman.Client, s state.Store,
	n net.Net, m dnsmasq.Manager, vmIP, uid string, caChanged bool) error {

	ui.Step(out, "Rescanning data volume")
	if err := project.Rescan(ctx, out, s); err != nil {
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
	// The rescan may have found projects and databases the DNS block
	// does not carry yet.
	if err := PublishDNS(ctx, out, m, n, s, false); err != nil {
		return err
	}

	if !caChanged {
		return nil
	}
	// A new CA invalidates every leaf, so drop the old pair and reissue.
	ui.Step(out, "Reconciling TLS certificates")
	for _, pr := range s.Projects() {
		if pr.Name == "" {
			continue
		}
		for _, f := range []string{"cert.pem", "key.pem", "cert.sans"} {
			_ = os.Remove(srv.MetaFile(pr.Name, f))
		}
		if err := project.EnsureCert(ctx, out, pr.Name, pr.URLs, n, p, uid); err != nil {
			ui.Warn(out, "cert for '%s': %v", pr.Name, err)
		}
	}
	return nil
}

// refuseLegacyRuntime stops setup when a runtime container from before
// this layout still holds the project address on the bridge. Two owners
// of one address on one segment is an ARP conflict, so the container has
// to go first. Refusing rather than removing keeps migration logic out
// of the shipped path; mpd-virt's upgrade script does the removal.
func refuseLegacyRuntime(ctx context.Context, out io.Writer, p *podman.Client, n net.Net) error {
	var found []string
	for _, item := range p.Ps(ctx, "label=mpd.runtime") {
		found = append(found, item.Name())
	}
	if len(found) == 0 {
		return nil
	}
	ui.Warn(out, "legacy runtime container(s): %s", strings.Join(found, ", "))
	return fmt.Errorf("A runtime container still holds %s. Run mpd-virt's upgrade/03-remove-runtime.sh %s, then retry.",
		n.IP(net.HostProjects), n.VMID())
}

// configureStack runs the dev-stack converge: PHP config, the php
// dispatcher, Composer and Node. Composer and Node are upstream
// fetches, which is why they are here and not in bootstrap.
func configureStack(ctx context.Context, out io.Writer) error {
	code, err := exec.Run(ctx, exec.Cmd{
		Name: "bash", Args: []string{"/opt/mpd/assets/vm/configure-stack.sh"},
		Stdout: out, Stderr: out,
	})
	if err != nil || code != 0 {
		return fmt.Errorf("configure-stack.sh failed.")
	}
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

// copyFile duplicates src at dst. A copy, never a symlink: the anchor
// is compared byte for byte by cert.ResolveSigner.
func copyFile(src, dst string, mode os.FileMode) error {
	data, err := os.ReadFile(src)
	if err != nil {
		return err
	}
	return os.WriteFile(dst, data, mode)
}
