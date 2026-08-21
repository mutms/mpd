package cli

// `mpd --vm-diag`: a read-only sweep that answers "is this VM actually
// working?" in one screen.
//
// Deliberately distinct from `--vm-status`, which renders mpd's own state
// files — requested versus observed. Diag *probes*: it resolves a name,
// opens a socket, reads a certificate issuer. That difference is the
// whole point, because the failures worth catching here leave the state
// files looking perfect. A corporate VPN that captures DNS, claims the
// container subnet, or intercepts TLS breaks every one of these probes
// while `--vm-status` keeps reporting a healthy VM.
//
// Nothing here changes the system. Every probe is a read, a lookup or a
// dial, so it is safe to run at any time, including mid-incident.

import (
	"context"
	"crypto/tls"
	"crypto/x509"
	"encoding/pem"
	"fmt"
	"io"
	gonet "net"
	"os"
	"path/filepath"
	"strings"
	"time"

	"github.com/mutms/mpd/go/internal/current"
	"github.com/mutms/mpd/go/internal/exec"
	"github.com/mutms/mpd/go/internal/net"
	"github.com/mutms/mpd/go/internal/podman"
	"github.com/mutms/mpd/go/internal/runtime"
	"github.com/mutms/mpd/go/internal/service"
	"github.com/mutms/mpd/go/internal/state"
	"github.com/mutms/mpd/go/internal/ui"
	"github.com/mutms/mpd/go/internal/vm"
)

// diagTimeout bounds every dial and lookup. Short on purpose: a probe
// that hangs is itself the finding, and a wedged resolver must not be
// able to stall the sweep.
const diagTimeout = 3 * time.Second

// caExpiryWarning is how close to expiry a certificate gets a warning
// rather than a pass. A month is enough notice to reissue calmly.
const caExpiryWarning = 30 * 24 * time.Hour

// DiagDeps is what the sweep needs. Same shape as the other read-only
// commands: concrete collaborators, passed in.
type DiagDeps struct {
	Net      net.Net
	Podman   *podman.Client
	State    state.Store
	Observer current.Observer
	// ControlSocket is the runtime's control endpoint. Passed in rather
	// than derived: internal/control imports this package, so naming its
	// path here would close an import cycle.
	ControlSocket string
	// Version is the running binary's stamped version, from main.
	Version string
}

// Diag runs every probe and returns a non-nil error when any of them
// failed, so the command is usable as a scripted health gate. Warnings
// do not fail the run: they flag something worth knowing that still
// leaves the VM working.
func Diag(ctx context.Context, out io.Writer, d DiagDeps) error {
	r := &diagRun{out: out}

	diagVersion(r, d)
	diagIdentity(ctx, r, d)
	diagNetwork(ctx, r, d)
	diagTLS(ctx, r, d)
	diagRuntime(ctx, r, d)
	diagDesktop(ctx, r)
	diagData(ctx, r, d)

	return r.summary()
}

// diagRun accumulates results while printing them, so a slow probe shows
// its line as it completes rather than after the whole sweep.
type diagRun struct {
	out               io.Writer
	nOK, nWarn, nFail int
}

func (r *diagRun) step(format string, args ...any) { ui.Step(r.out, format, args...) }
func (r *diagRun) note(format string, args ...any) { ui.Note(r.out, format, args...) }

func (r *diagRun) ok(format string, args ...any) {
	r.nOK++
	ui.OK(r.out, format, args...)
}

func (r *diagRun) warn(format string, args ...any) {
	r.nWarn++
	ui.Warn(r.out, format, args...)
}

func (r *diagRun) fail(format string, args ...any) {
	r.nFail++
	ui.Fail(r.out, format, args...)
}

func (r *diagRun) summary() error {
	r.step("Summary")
	total := r.nOK + r.nWarn + r.nFail
	switch {
	case r.nFail > 0:
		ui.Fail(r.out, "%d of %d checks failed (%d warnings)", r.nFail, total, r.nWarn)
		return fmt.Errorf("%d diagnostic check(s) failed", r.nFail)
	case r.nWarn > 0:
		ui.OK(r.out, "%d checks passed, %d warnings", r.nOK, r.nWarn)
	default:
		ui.OK(r.out, "all %d checks passed", total)
	}
	return nil
}

// --- Version -------------------------------------------------------------

// diagVersion opens the sweep by naming the binary that produced it.
// First because every line below is only meaningful against a known
// version — a diag pasted into a bug report without one is a description
// of an unknown program.
func diagVersion(r *diagRun, d DiagDeps) {
	r.step("mpd")
	r.note("version %s (%s)", d.Version, vm.BinaryPath)

	c := d.State.Config()
	switch {
	case c.LastUpgradeVersion == "":
		r.note("last --vm-upgrade: never run on this VM")
	case c.LastUpgradeVersion == d.Version:
		r.note("last --vm-upgrade: %s, %s", c.LastUpgradeVersion, diagWhen(c.LastUpgradeAt))
	default:
		// Running something other than what the last upgrade installed is
		// normal on a VM where mpd itself is developed (a local `make
		// install`), and a real finding anywhere else.
		r.note("last --vm-upgrade: %s, %s — the running binary is a local build",
			c.LastUpgradeVersion, diagWhen(c.LastUpgradeAt))
	}
}

// diagWhen renders a recorded timestamp as a date plus how long ago, and
// falls back to the raw string rather than hiding a value it cannot parse.
func diagWhen(stamp string) string {
	t, err := time.Parse(time.RFC3339, stamp)
	if err != nil {
		return stamp
	}
	days := int(time.Since(t).Hours() / 24)
	if days < 1 {
		return t.Format(time.DateOnly) + " (today)"
	}
	return fmt.Sprintf("%s (%d days ago)", t.Format(time.DateOnly), days)
}

// --- Identity and certificates ------------------------------------------

func diagIdentity(ctx context.Context, r *diagRun, d DiagDeps) {
	r.step("Identity")
	r.note("vm id %s, zone %s, subnet %s", d.Net.VMID(), d.Net.Zone(), d.Net.Subnet())

	anchor := diagCert(r, vm.CACertPath, "trust anchor")
	signer := diagCert(r, vm.SigningCertPath, "signing CA")
	if anchor != nil && signer != nil && !anchor.Equal(signer) {
		r.note("signer is an intermediate constrained to this zone (mpd-virt provisioned)")
	}

	// The trust store copy must be the same certificate as the anchor.
	// A stale copy is the classic "browser still does not trust it after
	// re-running setup" cause, and comparing bytes is the only way to see
	// it: both files exist and both parse.
	if anchor != nil {
		if store, err := readCert(vm.TrustStorePath); err != nil {
			r.fail("CA not in the system trust store (%s) — run `mpd --vm-setup`", vm.TrustStorePath)
		} else if !store.Equal(anchor) {
			r.fail("system trust store holds a DIFFERENT certificate than %s — run `mpd --vm-setup`", vm.CACertPath)
		} else {
			r.ok("CA present in the system trust store")
		}
	}

	diagNSSDB(ctx, r)
}

// diagCert parses one PEM certificate and reports presence and validity.
// Returns nil when it could not be read, so callers can skip comparisons
// that would be meaningless.
func diagCert(r *diagRun, path, label string) *x509.Certificate {
	c, err := readCert(path)
	if err != nil {
		r.fail("%s missing or unreadable at %s — run `mpd --vm-setup`", label, path)
		return nil
	}
	switch remaining := time.Until(c.NotAfter); {
	case remaining <= 0:
		r.fail("%s EXPIRED on %s", label, c.NotAfter.Format(time.DateOnly))
		return c
	case remaining < caExpiryWarning:
		r.warn("%s expires %s (in %d days)", label, c.NotAfter.Format(time.DateOnly), int(remaining.Hours()/24))
		return c
	default:
		r.ok("%s valid until %s", label, c.NotAfter.Format(time.DateOnly))
		return c
	}
}

func readCert(path string) (*x509.Certificate, error) {
	raw, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	block, _ := pem.Decode(raw)
	if block == nil {
		return nil, fmt.Errorf("%s holds no PEM block", path)
	}
	return x509.ParseCertificate(block.Bytes)
}

// diagNSSDB checks the Chromium-family trust store, which is a separate
// database from the system one and goes stale independently.
func diagNSSDB(ctx context.Context, r *diagRun) {
	dir := filepath.Join(vm.Home(), ".pki", "nssdb")
	if _, err := os.Stat(filepath.Join(dir, "cert9.db")); err != nil {
		r.warn("no NSS DB at %s — Chromium will not trust project URLs (run `mpd --vm-setup`)", dir)
		return
	}
	if !exec.Available("certutil") {
		r.warn("certutil not installed (apt: libnss3-tools) — cannot check the Chromium trust store")
		return
	}
	res, err := exec.Capture(ctx, exec.Cmd{
		Name: "certutil",
		Args: []string{"-L", "-d", "sql:" + dir},
	})
	if err != nil || res.Failed() || !strings.Contains(res.Stdout, "mpd CA") {
		r.warn("mpd CA not in %s — Chromium will warn on project URLs (run `mpd --vm-setup`)", dir)
		return
	}
	r.ok("mpd CA present in the Chromium trust store (~/.pki/nssdb)")
}

// --- Networking ----------------------------------------------------------

func diagNetwork(ctx context.Context, r *diagRun, d DiagDeps) {
	r.step("Network")

	gateway := d.Net.Gateway()

	// The bridge carries everything mpd serves from the VM. Without the
	// gateway address on it, dnsmasq and caddy have nothing to bind.
	res, err := exec.Capture(ctx, exec.Cmd{
		Name: "ip",
		Args: []string{"-o", "-4", "addr", "show", "dev", vm.BridgeName},
	})
	switch {
	case err != nil || res.Failed():
		r.fail("bridge %s is missing — run `mpd --vm-setup`", vm.BridgeName)
	case !strings.Contains(res.Stdout, gateway+"/"):
		r.fail("bridge %s is up but does not hold %s", vm.BridgeName, gateway)
	default:
		r.ok("bridge %s up at %s", vm.BridgeName, gateway)
	}

	if vm.UnitActive(ctx, vm.DnsmasqUnit, false) {
		r.ok("resolver running (%s)", vm.DnsmasqUnit)
	} else {
		r.fail("resolver not running (%s) — no .test name will resolve", vm.DnsmasqUnit)
	}

	// Zone resolution through the *system* resolver, not by asking dnsmasq
	// directly: that is the path everything else on the VM takes, and it is
	// the one a VPN's resolver takeover breaks.
	if addrs := diagLookup(ctx, d.Net.Zone()); len(addrs) == 0 {
		r.fail("%s does not resolve through the system resolver", d.Net.Zone())
	} else if !contains(addrs, gateway) {
		r.fail("%s resolves to %s, expected %s — something else is answering for .test",
			d.Net.Zone(), strings.Join(addrs, ", "), gateway)
	} else {
		r.ok("%s resolves to %s", d.Net.Zone(), gateway)
	}

	// The zone answers from a local hosts file even when the resolver has
	// no upstream at all, so forwarding needs its own probe — see
	// vm.ForwardsUpstream.
	if vm.ForwardsUpstream(ctx, gateway) {
		r.ok("resolver forwards upstream (%s answers)", vm.UpstreamProbeName)
	} else {
		r.fail("resolver cannot forward upstream — %s does not resolve, so apt and git will fail inside containers",
			vm.UpstreamProbeName)
	}

	diagSubnetRoute(ctx, r, d)

	if vm.FirewallLoaded(ctx) {
		r.ok("container subnet sealed from the LAN (nftables table loaded)")
	} else {
		r.warn("mpd firewall table not loaded — the container subnet may be reachable from the LAN (run `mpd --vm-setup`)")
	}

	if vm.UnitActive(ctx, vm.WebUnitName, true) {
		r.ok("portal running (%s)", vm.WebUnitName)
	} else {
		r.warn("portal not running (%s) — https://%s/ will not answer", vm.WebUnitName, d.Net.Zone())
	}
}

// diagSubnetRoute is the VPN tripwire. A full-tunnel client that claims
// RFC1918 space sends container traffic into its own interface, at which
// point every project URL times out while every state file still says the
// project is running.
func diagSubnetRoute(ctx context.Context, r *diagRun, d DiagDeps) {
	target := d.Net.IP(net.HostRuntime)
	res, err := exec.Capture(ctx, exec.Cmd{Name: "ip", Args: []string{"route", "get", target}})
	if err != nil || res.Failed() {
		r.fail("no route to the container subnet (%s)", d.Net.Subnet())
		return
	}
	dev := routeDevice(res.Stdout)
	switch {
	case dev == vm.BridgeName:
		r.ok("container subnet routes via %s", vm.BridgeName)
	case dev == "":
		r.warn("could not read the route to %s: %s", target, strings.TrimSpace(res.Stdout))
	default:
		r.fail("container subnet routes via %q, not %s — a VPN or tunnel has claimed %s",
			dev, vm.BridgeName, d.Net.Subnet())
	}
}

// routeDevice pulls the interface out of `ip route get` output, which
// reads "10.163.200.2 dev mpdbr0 src 10.163.200.1 uid 1000".
func routeDevice(out string) string {
	fields := strings.Fields(out)
	for i, f := range fields {
		if f == "dev" && i+1 < len(fields) {
			return fields[i+1]
		}
	}
	return ""
}

func diagLookup(ctx context.Context, name string) []string {
	ctx, cancel := context.WithTimeout(ctx, diagTimeout)
	defer cancel()
	addrs, err := gonet.DefaultResolver.LookupHost(ctx, name)
	if err != nil {
		return nil
	}
	return addrs
}

func contains(haystack []string, needle string) bool {
	for _, h := range haystack {
		if h == needle {
			return true
		}
	}
	return false
}

// --- TLS -----------------------------------------------------------------

// diagTLS is the interception tripwire. It verifies the portal's chain
// against this VM's own anchor rather than the system store, so a
// corporate CA that has been installed system-wide cannot make an
// intercepted connection look fine.
func diagTLS(ctx context.Context, r *diagRun, d DiagDeps) {
	r.step("TLS")

	anchor, err := readCert(vm.CACertPath)
	if err != nil {
		r.warn("skipping the portal certificate check — no anchor at %s", vm.CACertPath)
		return
	}
	pool := x509.NewCertPool()
	pool.AddCert(anchor)

	addr := gonet.JoinHostPort(d.Net.Zone(), "443")
	dialer := &gonet.Dialer{Timeout: diagTimeout}

	conn, err := tls.DialWithDialer(dialer, "tcp", addr, &tls.Config{
		RootCAs:    pool,
		ServerName: d.Net.Zone(),
		MinVersion: tls.VersionTLS12,
	})
	if err == nil {
		conn.Close()
		r.ok("portal certificate chains to this VM's CA")
		return
	}

	// Verification failed. Dial again without checking, purely so the
	// message can name what is actually being served — "issued by
	// <corporate CA>" turns a mystery into a diagnosis.
	insecure, derr := tls.DialWithDialer(dialer, "tcp", addr, &tls.Config{
		InsecureSkipVerify: true, //nolint:gosec // diagnostic: reports the issuer it finds
		ServerName:         d.Net.Zone(),
		MinVersion:         tls.VersionTLS12,
	})
	if derr != nil {
		r.fail("portal https://%s/ is not answering on 443: %v", d.Net.Zone(), err)
		return
	}
	defer insecure.Close()

	certs := insecure.ConnectionState().PeerCertificates
	if len(certs) == 0 {
		r.fail("portal served no certificate")
		return
	}
	r.fail("portal certificate does NOT chain to this VM's CA — issued by %q. TLS is being intercepted.",
		certs[0].Issuer.CommonName)
}

// --- Runtime -------------------------------------------------------------

func diagRuntime(ctx context.Context, r *diagRun, d DiagDeps) {
	r.step("Runtime")

	container := d.Observer.RuntimeContainer(runtime.Name)
	switch d.Observer.Runtime(ctx, runtime.Name) {
	case current.Missing:
		r.fail("runtime container %s does not exist — run `mpd --vm-setup`", container)
		return
	case current.Stopped:
		r.fail("runtime container %s is stopped — run `mpd --vm-start`", container)
		return
	default:
		r.ok("runtime container %s running", container)
	}

	want := d.Net.IP(net.HostRuntime)
	if got := d.Podman.ContainerIP(ctx, container, "mpd-internal"); got != want {
		r.fail("runtime is at %q, expected %s", got, want)
	} else {
		r.ok("runtime addressed at %s", want)
	}

	if diagDial(want, "22") {
		r.ok("runtime sshd reachable (ssh %s)", d.Net.RuntimeAlias())
	} else {
		r.fail("runtime sshd not reachable at %s:22 — IDE and `ssh` sessions will fail", want)
	}

	// The control socket is how `mpd` run inside the runtime reaches the
	// VM. Its absence is invisible until a tool in the container tries.
	sock := d.ControlSocket
	if _, err := os.Stat(sock); err != nil {
		r.fail("control socket missing at %s — `mpd` inside the runtime will not work", sock)
	} else if !diagDialUnix(sock) {
		r.fail("control socket at %s is not accepting connections (%s)", sock, vm.ControlUnitName)
	} else {
		r.ok("control socket accepting connections")
	}
}

// --- Desktop and remote access -------------------------------------------

// diagDesktop reports the optional desktop layer. Absence is never a
// failure — a headless VM is the default and the supported shape — but a
// desktop that cannot possibly render is, because that state is silent:
// GNOME installs cleanly on a kernel with no DRM drivers and then shows a
// black console with nothing in any log.
func diagDesktop(ctx context.Context, r *diagRun) {
	r.step("Desktop and remote access")

	if _, err := os.Stat("/usr/bin/gnome-session"); err != nil {
		r.note("GNOME not installed (headless VM — `gnome-install` adds it)")
		// Not a problem while the VM stays headless, but it decides
		// whether `gnome-install` can ever produce a visible desktop, and
		// finding that out afterwards costs a kernel swap and a reboot.
		if k := kernelRelease(); strings.Contains(k, "-cloud") {
			r.note("kernel %s has no DRM drivers — a desktop here would need "+
				"linux-image-amd64 first", k)
		}
	} else {
		r.ok("GNOME installed")

		cards, _ := filepath.Glob("/dev/dri/card*")
		if len(cards) == 0 {
			hint := "install a kernel with DRM drivers and reboot"
			if k := kernelRelease(); strings.Contains(k, "-cloud") {
				hint = fmt.Sprintf("kernel %s is Debian's cloud kernel, which ships none: "+
					"install linux-image-amd64 and reboot", k)
			}
			r.fail("no DRM device (/dev/dri) — the console will be black. %s", hint)
		} else {
			r.ok("graphics device present (%s)", strings.Join(baseNames(cards), " "))
		}

		target := diagDefaultTarget(ctx)
		if target == "graphical.target" {
			r.note("boot target graphical (desktop on) — `gnome-stop` returns to headless")
		} else {
			r.note("boot target %s (headless) — `gnome-start` brings the desktop up", target)
		}
		if vm.UnitActive(ctx, "gdm3", false) {
			r.ok("display manager running (gdm3)")
		} else {
			r.note("display manager not running")
		}
	}

	if _, err := os.Stat("/usr/sbin/xrdp"); err != nil {
		r.note("RDP not installed (`rdp-start` installs and opens it)")
		return
	}
	switch {
	case vm.UnitActive(ctx, "xrdp", false) && diagDial("127.0.0.1", "3389"):
		r.warn("RDP is OPEN on tcp/3389 — the one port held by a password, not a key. `rdp-stop` closes it")
	case vm.UnitActive(ctx, "xrdp", false):
		r.fail("xrdp is running but nothing is listening on 3389")
	default:
		r.note("RDP installed but stopped (`rdp-start` reopens it)")
	}
}

// kernelRelease is `uname -r` without the exec: the flavour suffix is
// what decides whether this kernel carries DRM drivers at all.
func kernelRelease() string {
	raw, err := os.ReadFile("/proc/sys/kernel/osrelease")
	if err != nil {
		return ""
	}
	return strings.TrimSpace(string(raw))
}

func diagDefaultTarget(ctx context.Context) string {
	res, err := exec.Capture(ctx, exec.Cmd{Name: "systemctl", Args: []string{"get-default"}})
	if err != nil || res.Failed() {
		return "unknown"
	}
	return strings.TrimSpace(res.Stdout)
}

func baseNames(paths []string) []string {
	out := make([]string, 0, len(paths))
	for _, p := range paths {
		out = append(out, filepath.Base(p))
	}
	return out
}

// --- Projects, databases, services ---------------------------------------

// diagData compares intent against reality for everything mpd was asked
// to keep running. A container that was asked to run and is not is the
// single most common "it worked yesterday".
func diagData(ctx context.Context, r *diagRun, d DiagDeps) {
	r.step("Projects, databases and services")

	projects := d.State.Projects()
	wantRunning := 0
	for _, p := range projects {
		if p.Autostart {
			wantRunning++
		}
	}
	r.note("%d project(s) registered, %d marked started", len(projects), wantRunning)

	for _, db := range d.State.Databases() {
		if !db.Autostart {
			continue
		}
		if d.Podman.Running(ctx, db.ContainerName) {
			r.ok("database %s (%s:%s) running", db.DatabaseID, db.Engine, db.Version)
		} else {
			r.fail("database %s is marked started but its container %s is not running",
				db.DatabaseID, db.ContainerName)
		}
	}

	for _, entry := range d.State.Services() {
		if !entry.Enabled {
			continue
		}
		// Ask the registry for the container name — composing it here
		// would be a second copy of the naming rule.
		svc, known := service.Find(entry.Name)
		if !known {
			r.warn("service %q is enabled but is not a known service", entry.Name)
			continue
		}
		if d.Podman.Running(ctx, svc.Container()) {
			r.ok("service %s running", entry.Name)
		} else {
			r.fail("service %s is enabled but %s is not running", entry.Name, svc.Container())
		}
	}
}

// --- Dialling ------------------------------------------------------------

func diagDial(host, port string) bool {
	c, err := gonet.DialTimeout("tcp", gonet.JoinHostPort(host, port), diagTimeout)
	if err != nil {
		return false
	}
	c.Close()
	return true
}

func diagDialUnix(path string) bool {
	c, err := gonet.DialTimeout("unix", path, diagTimeout)
	if err != nil {
		return false
	}
	c.Close()
	return true
}
