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
	"github.com/mutms/mpd/go/internal/web"
)

// Network is the podman network every mpd container attaches to, and
// NetworkInterface is the host bridge it hangs off.
//
// The bridge is named rather than left to podman's podman0/podman1
// counter, whose value depends on what other networks happened to be
// created first: mpd's resolver names that interface in its config to
// bind the gateway, so a name that drifts is a name that silently stops
// resolving.
//
// NOT "mpd0", however obvious that looks. That was the WireGuard tunnel
// mpd used before it moved to a routed subnet (removed 2026-07-20), and
// every VM bootstrapped before then still brings one up at boot from an
// enabled wg-quick@mpd0.service. netavark then refuses to create the
// network at all: "bridge interface mpd0 already exists but is a
// Wireguard interface". The "br" keeps the two apart for good.
const (
	Network          = "mpd-internal"
	NetworkInterface = "mpdbr0"
)

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
//   - identity (the hostname) before anything that composes a name or an
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

	n, vmIP, err := setupIdentity(ctx, out)
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

	// After Configuration, which is where the dev user's name is resolved.
	ui.Step(out, "Runtime SSH aliases")
	if err := vm.EnsureSSHConfig(out, user.User, runtimeSSHHosts(n)); err != nil {
		return err
	}

	ui.Step(out, "VM shell prompt")
	if err := vm.EnsurePrompt(out); err != nil {
		return err
	}

	ui.Step(out, "VM vim defaults")
	if err := vm.EnsureVimrc(out); err != nil {
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
	if err := setupNetworkAndVolume(ctx, out, p, n); err != nil {
		return err
	}

	// After the podman network is *registered* (netavark records mpd-internal's
	// subnet before any bridge owns it) but before dnsmasq and caddy bind the
	// gateway: create the static bridge mpdbr0 (a systemd oneshot) with the
	// gateway address, so it exists at boot and netavark just attaches
	// containers to it instead of creating one on demand. wg0 gives the Mac an
	// encrypted path to 10.163.<NNN>.x (peer added by mpd-virt).
	if err := vm.EnsureBridge(ctx, out, n.Gateway()+"/24"); err != nil {
		return err
	}
	if err := vm.EnsureWireGuard(ctx, out, n.Octet()); err != nil {
		return err
	}
	// Seal the container subnet from the LAN: only the bridge itself and
	// wg0 (the MacBook overlay, which carries the whole /24) may route
	// into 10.163.<NNN>.0/24. Container outbound NAT is untouched.
	if err := vm.EnsureFirewall(ctx, out, n.Subnet()); err != nil {
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

	// The records first, then the resolver that serves them: dnsmasq reads
	// /etc/hosts on start, so a block written before the (re)start needs
	// no reload, and a VM whose cloud-init would wipe the block at boot is
	// told not to before the block is ever relied on.
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

	// Before the runtime, not after it: building the runtime base runs
	// apt inside a container that resolves through this resolver, so a
	// resolver that is not answering yet fails that build minutes in,
	// with the cause several screens up. This used to sit at the end of
	// setup because the resolver binds the podman bridge and podman only
	// created that bridge once a container attached — no longer true:
	// mpd-bridge.service brings mpdbr0 up at boot, and the dnsmasq unit
	// orders itself after it.
	ui.Step(out, "DNS resolution")
	if err := vm.EnsureDnsmasqResolving(ctx, out, n.Gateway(), n.Zone()); err != nil {
		return err
	}
	// Fatal, unlike the report verifyDNS makes: without an upstream the
	// runtime build below cannot install a single package, and failing
	// here says why in one screen instead of a hundred lines of apt.
	if err := vm.RequireDNSUpstream(ctx, out, n.Gateway()); err != nil {
		return err
	}
	verifyDNS(ctx, out, n)

	// The unified runtime: created here rather than lazily, so setup
	// leaves the VM fully usable. Everything it needs exists by now —
	// the CA (certificates step), /srv (volume mount), DNS (just
	// verified) — and reconcileCaches has just adopted any existing entry.
	if err := setupRuntime(ctx, out, p, s, m, n, user); err != nil {
		return err
	}

	// Extra services: nothing is installed by default — this converges
	// whatever the developer has enabled (repairing revision drift), and
	// republishes the enabled-set meta for configure.sh.
	ui.Step(out, "Extra services")
	if err := ReconcileServices(ctx, out, p, s, n); err != nil {
		ui.Warn(out, "%v", err)
	}
	if err := WriteServicesMeta(s); err != nil {
		return err
	}
	if enabled := s.Services(); len(enabled) == 0 {
		ui.OK(out, "none enabled — mpd --service-enable=%s", strings.Join(service.Names(), "|"))
	}

	_, _ = p.PullQuiet(ctx, BaseImagePull)

	ui.Step(out, "Status web server (mpd --web)")
	if err := vm.InstallWebUnit(ctx); err != nil {
		return err
	}
	// Restarted on every run, not just when missing: `--vm-setup` is what
	// a developer reaches for after `make install`, and a server still
	// running the previous binary would serve stale templates with
	// nothing to show for it.
	ui.OK(out, "%s restarted (listening on %s).", vm.WebUnitName, web.Addr)

	ui.Step(out, "Control socket for runtimes (mpd --control)")
	if err := vm.InstallControlUnit(ctx); err != nil {
		return err
	}
	// Restarted for a sharper reason than the web server's: this daemon
	// carries the guard that decides what a runtime may ask for, so one
	// still running the previous binary would enforce the previous rules.
	ui.OK(out, "%s restarted (sockets under %s).", vm.ControlUnitName, podman.ControlRunDir)

	ui.Step(out, "TLS frontdoor (caddy)")
	// The VM's caddy serves exactly one name now: the zone apex, for the
	// portal. Extra services are HTTP-only at their own addresses —
	// reached over the WireGuard overlay or SOCKS, inside the trust
	// boundary — so nothing else needs TLS termination here.
	sites := []vm.CaddySite{
		{Host: n.Zone(), Upstream: web.Addr},
	}
	if err := vm.ConfigureCaddy(ctx, out, user.User, n.Gateway(),
		vm.ServiceDir+"/cert.pem", vm.ServiceDir+"/key.pem", sites,
		certs.ServiceCertChanged); err != nil {
		return err
	}

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
	// whatever orchestration called us — `mpd-virt` for a managed
	// VM, mpd-sandbox-setup.sh for the sandbox.
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
	if err := vm.EnsurePackages(ctx, out); err != nil {
		return err
	}
	// Before podman is touched: an Apple container has /proc/sys read-only,
	// which fails every podman sysctl write. Installs a boot-time remount
	// unit (a no-op on a real VM) and applies it now for this run too.
	if err := vm.EnsureProcSysWritable(ctx, out); err != nil {
		return err
	}
	return vm.EnablePodmanRestart(ctx, out)
}

// setupIdentity derives the VM's addressing from its hostname and reads
// its LAN IP off the interface. Both come live from the running VM — the
// hostname (mpd-<NNN>) is the single source of truth, and the IP is a
// fact about the box. It returns the Net and the VM's own IP (empty on a
// DHCP-less box).
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

// certState reports what setupCertificates changed, so the steps after it
// can react to the parts that concern them.
type certState struct {
	// CAChanged is true when the CA that signs leaves moved. It
	// invalidates every certificate derived from it, so service
	// containers are rebuilt and project certs reissued.
	CAChanged bool
	// ServiceCertChanged is true when the certificate caddy serves was
	// rewritten — on a CA change, on SAN drift, or on first creation.
	//
	// Tracked separately because caddy holds the certificate in memory
	// and its configuration does not mention the contents, only the path.
	// A reissued certificate therefore leaves the Caddyfile byte-identical
	// and would, without this, never be picked up: the VM would go on
	// serving a leaf signed by a CA that no longer exists.
	ServiceCertChanged bool
}

// setupCertificates ensures the CA and the service certificate exist and
// are current, reporting what it changed.
func setupCertificates(ctx context.Context, out io.Writer, n net.Net) (certState, error) {
	ui.Step(out, "Root CA certificate")
	// 0700 on both: one holds the CA private key, the other the openssl
	// scratch files that briefly contain key material.
	for _, dir := range []string{vm.CARootDir, vm.TempDir} {
		if err := vm.EnsureDir(dir, 0o700); err != nil {
			return certState{}, err
		}
	}

	// Which CA this VM signs with depends on how it was provisioned; see
	// cert.ResolveSigner. Absent entirely means nobody has pushed CA
	// material in, so this is a VM set up without mpd-virt: generate a
	// self-signed CA that acts as its own anchor.
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
	// Fingerprint the signer, not the anchor. What invalidates a leaf is a
	// change of whatever signed it, and on a VM with a per-zone
	// intermediate that can move while the anchor stays put — as it does
	// on every `mpd-virt refresh-ca`. Fingerprinting the anchor there would
	// report "nothing changed" and leave every project serving a
	// certificate signed by a CA that no longer exists.
	fingerprint := vm.Fingerprint(ctx, signer.CertPath)
	caChanged := readTrimmed(fingerprintPath) != fingerprint

	// SAN drift: the service cert covers exactly the zone apex, and the
	// zone changes when the VM's ID does. A cert issued for a previous
	// zone still verifies against the CA, so nothing else here would
	// notice — and every HTTPS hit on the portal would fail hostname
	// verification. Same signature-file pattern the project certs use.
	// Just the apex: the portal is the only thing the VM's own caddy
	// terminates TLS for. Extra services are HTTP-only at their own
	// addresses and never touch this certificate.
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

// runtimeSSHHosts builds the ~/.ssh/config entry for the runtime.
//
// The VM-qualified alias comes first because it is the unambiguous name
// here: in the VM the bare `mpd-130` is this machine's own hostname, so
// it cannot also mean the runtime. On the laptop it can, and does — the
// host-side block mpd-virt writes maps `mpd-130` to the runtime and
// `mpd-130-vm` to this VM. The bare `runtime` and the FQDN also answer.
func runtimeSSHHosts(n net.Net) []vm.RuntimeHost {
	fqdn := n.RuntimeFQDN()
	return []vm.RuntimeHost{{
		Patterns: []string{n.RuntimeAlias(), runtime.Name, fqdn},
		HostName: fqdn,
	}}
}

// setupHostTrust covers the three trust stores on the VM that have to
// learn about mpd's CA. (DNS needs no host-side hook: the VM reads mpd's
// records from /etc/hosts, see the DNS step in Setup.)
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
//
// Both network checks are refusals, not repairs, and for the same reason:
// neither property can be changed in place, so the honest move is to name
// the migration rather than report success on a network that is wrong.
//
//   - Subnet: fixed at creation. A network created under a different VM ID
//     keeps handing out addresses from the OLD subnet while mpd composes
//     DNS records and certificate SANs from the new one, so every name
//     resolves to an address nothing listens on.
//   - DNS: `podman network update` edits nameserver lists only, never the
//     dns_enabled flag. A network created with podman's DNS on has
//     aardvark-dns holding port 53 on the gateway, which is where mpd's
//     own resolver has to listen.
func setupNetworkAndVolume(ctx context.Context, out io.Writer, p *podman.Client, n net.Net) error {
	ui.Step(out, "Podman network")
	if p.NetworkExists(ctx, Network) {
		if reason := networkMismatch(ctx, p, n); reason != "" {
			return fmt.Errorf(`Podman network '%s' %s

That cannot be changed in place. Migrate — destroys containers, keeps the data volume:

    sudo podman rm -af
    sudo podman network rm %s
    mpd --vm-setup

Then recreate runtimes and DB containers; /srv/ (projects, data, databases) is on the data volume and survives. No reboot needed — `+
				"`podman rm -af`"+` stops the containers, and `+"`mpd --vm-setup`"+` rebuilds the network, records, and certs in place.`,
				Network, reason, Network)
		}
		ui.OK(out, "Network '%s' already exists (%s).", Network, n.Subnet())
	} else {
		if code, err := p.NetworkCreate(ctx, Network, NetworkInterface, n.Subnet()); err != nil || code != 0 {
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

	// Copied from the template once and never overwritten. On a sandbox VM
	// it is the developer's file after that; on a managed VM mpd-virt
	// pushes the Mac's copy over it, and this seeding only decides what a
	// VM starts with before the first push.
	ui.Step(out, "mpd-virt.env defaults")
	if err := os.MkdirAll(vm.EnvDir, 0o755); err != nil {
		return err
	}
	target := filepath.Join(vm.EnvDir, "mpd-virt.env")
	if exists(target) {
		ui.OK(out, "%s already exists — edit to set your defaults.", target)
		return nil
	}
	source := filepath.Join(vm.AssetsDir, "vm", "mpd-virt.env")
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
	// The rescan above may have found projects and databases the block does
	// not carry yet.
	if err := PublishDNS(ctx, out, m, n, s, false); err != nil {
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

// setupRuntime converges the unified runtime: create it when missing,
// start it when stopped, leave it alone when running. Clean break from
// the pod era — legacy per-language runtime pods are reported loudly
// rather than migrated.
func setupRuntime(ctx context.Context, out io.Writer, p *podman.Client, s state.Store,
	m dnsmasq.Manager, n net.Net, user vm.Identity) error {

	ui.Step(out, "Runtime container")

	var legacy []string
	for _, item := range p.Ps(ctx, "label=mpd.runtime") {
		if item.Label("mpd.name") != runtime.Name {
			legacy = append(legacy, item.Name())
		}
	}
	if len(legacy) > 0 {
		ui.Warn(out, "legacy runtime container(s) found: %s", strings.Join(legacy, ", "))
		ui.Warn(out, "this mpd uses a single unified runtime — remove them with: podman pod rm -f <name>")
	}

	o := current.NewObserver(n.VMID(), p)
	container := o.RuntimeContainer(runtime.Name)
	home, err := os.UserHomeDir()
	if err != nil {
		return err
	}
	switch {
	case !p.Exists(ctx, container):
		return RuntimeCreate(ctx, out, p, s, m, o, n, user.User, user.UID, home)
	case !p.Running(ctx, container):
		return RuntimeStart(ctx, out, p, s, m, o, n, user.User, user.UID)
	}
	ui.OK(out, "runtime is running (%s).", container)
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

// copyFile duplicates src at dst with the given mode. Used to publish a
// self-signed signing CA as its own trust anchor, which is why it copies
// rather than symlinks: the anchor is read by trust stores and by
// cert.ResolveSigner's byte comparison, and a link would make "are these
// the same certificate?" depend on how the question was asked.
func copyFile(src, dst string, mode os.FileMode) error {
	data, err := os.ReadFile(src)
	if err != nil {
		return err
	}
	return os.WriteFile(dst, data, mode)
}
