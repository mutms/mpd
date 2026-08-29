package cli

// `mpd --vm-diag`: a read-only sweep of live probes, unlike `--vm-status`
// which renders state files. The failures worth catching — a VPN that
// captures DNS, claims the subnet, or intercepts TLS — leave the state
// files looking perfect. Every probe is a read, lookup or dial; safe to
// run mid-incident.

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

// diagTimeout bounds every dial and lookup; a wedged resolver must not
// stall the sweep.
const diagTimeout = 3 * time.Second

// caExpiryWarning is how close to expiry a certificate gets a warning
// rather than a pass.
const caExpiryWarning = 30 * 24 * time.Hour

// DiagDeps is what the sweep needs.
type DiagDeps struct {
	Net      net.Net
	Podman   *podman.Client
	State    state.Store
	Observer current.Observer
	// ControlSocket is passed in rather than derived: internal/control
	// imports this package, so naming its path here closes an import
	// cycle.
	ControlSocket string
	// Version is the running binary's stamped version, from main.
	Version string
}

// Diag runs every probe and returns an error when any failed, so the
// command works as a scripted health gate. Warnings do not fail the run.
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

// diagRun accumulates results while printing them, so a slow probe
// shows its line as it completes.
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

// diagVersion opens the sweep by naming the binary that produced it —
// a diag pasted into a bug report needs a version.
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
		// A version other than the last upgrade's is normal where mpd is
		// developed (local `make install`), a real finding anywhere else.
		r.note("last --vm-upgrade: %s, %s — the running binary is a local build",
			c.LastUpgradeVersion, diagWhen(c.LastUpgradeAt))
	}
}

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

func diagIdentity(ctx context.Context, r *diagRun, d DiagDeps) {
	r.step("Identity")
	r.note("vm id %s, zone %s, subnet %s", d.Net.VMID(), d.Net.Zone(), d.Net.Subnet())

	anchor := diagCert(r, vm.CACertPath, "trust anchor")
	signer := diagCert(r, vm.SigningCertPath, "signing CA")
	if anchor != nil && signer != nil && !anchor.Equal(signer) {
		r.note("signer is an intermediate constrained to this zone (mpd-virt provisioned)")
	}

	// The trust store copy must equal the anchor. A stale copy is the
	// classic "browser still does not trust it" cause, and only a byte
	// comparison sees it — both files exist and both parse.
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

// diagCert parses one PEM certificate and reports presence and
// validity; nil when unreadable.
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

// diagNSSDB checks the Chromium-family trust store, a separate database
// that goes stale independently of the system one.
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

func diagNetwork(ctx context.Context, r *diagRun, d DiagDeps) {
	r.step("Network")

	gateway := d.Net.Gateway()

	// Without the gateway address on the bridge, dnsmasq and caddy have
	// nothing to bind.
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

	// Resolve through NSS, not dnsmasq directly: that is the path
	// everything else takes, and the one a stray hosts edit breaks.
	if addrs := diagLookup(ctx, d.Net.Zone()); len(addrs) == 0 {
		r.fail("%s does not resolve on the VM — mpd's block is missing from /etc/hosts (run `mpd --vm-setup`)", d.Net.Zone())
	} else if !contains(addrs, gateway) {
		r.fail("%s resolves to %s, expected %s — something answers before /etc/hosts",
			d.Net.Zone(), strings.Join(addrs, ", "), gateway)
	} else {
		r.ok("%s resolves to %s", d.Net.Zone(), gateway)
	}

	// The zone answers from /etc/hosts even with no upstream, so
	// forwarding needs its own probe.
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

// diagSubnetRoute is the VPN tripwire: a full-tunnel client that claims
// RFC1918 space sends container traffic into its own interface, and
// every project URL times out while state files look healthy.
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

// routeDevice pulls the interface out of `ip route get` output
// ("10.163.200.2 dev mpdbr0 src 10.163.200.1 uid 1000").
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

// diagTLS is the interception tripwire. It verifies the portal's chain
// against this VM's own anchor, not the system store, so a system-wide
// corporate CA cannot make an intercepted connection look fine.
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
	// message can name the issuer actually being served.
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

	// The control socket is how `mpd` inside the runtime reaches the VM;
	// its absence is invisible until a tool in the container tries.
	sock := d.ControlSocket
	if _, err := os.Stat(sock); err != nil {
		r.fail("control socket missing at %s — `mpd` inside the runtime will not work", sock)
	} else if !diagDialUnix(sock) {
		r.fail("control socket at %s is not accepting connections (%s)", sock, vm.ControlUnitName)
	} else {
		r.ok("control socket accepting connections")
	}
}

// diagDesktop reports the optional desktop layer. Absence is never a
// failure, but a desktop that cannot render is: GNOME installs cleanly
// on a kernel with no DRM drivers and then shows a black console with
// nothing in any log.
func diagDesktop(ctx context.Context, r *diagRun) {
	r.step("Desktop and remote access")

	if _, err := os.Stat("/usr/bin/gnome-session"); err != nil {
		r.note("GNOME not installed (headless VM — `gnome-install` adds it)")
		// The kernel flavour decides whether `gnome-install` can ever
		// render; finding out afterwards costs a kernel swap and reboot.
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
		// GNOME runs once per user: with a console session holding the
		// user units, an RDP login gets a silent black screen. Reported
		// here because the console login usually happens after rdp-start.
		user := vm.DetectIdentity().User
		if s := diagConsoleSession(ctx); s != "" {
			r.warn("...and %s holds a console session (%s) — an RDP login will get a black screen",
				user, s)
		}
		// Autologin recreates the collision at every boot, so terminating
		// the session is not a fix. Report it even with no live session.
		if who := gdmAutoLogin(); who != "" {
			r.warn("...and gdm autologin is on for %s — the console claims the desktop at every boot. "+
				"`gnome-stop` is the fix; terminating the session only lasts until the next reboot", who)
		} else if diagConsoleSession(ctx) != "" {
			r.note("`gnome-stop` to stay headless, or log out at the console before connecting")
		}
	case vm.UnitActive(ctx, "xrdp", false):
		r.fail("xrdp is running but nothing is listening on 3389")
	default:
		r.note("RDP installed but stopped (`rdp-start` reopens it)")
	}
}

// kernelRelease is `uname -r` without the exec.
func kernelRelease() string {
	raw, err := os.ReadFile("/proc/sys/kernel/osrelease")
	if err != nil {
		return ""
	}
	return strings.TrimSpace(string(raw))
}

// gdmAutoLogin returns the user gdm logs in automatically, or "" when
// autologin is off.
func gdmAutoLogin() string {
	raw, err := os.ReadFile("/etc/gdm3/daemon.conf")
	if err != nil {
		return ""
	}
	return parseGDMAutoLogin(string(raw))
}

// parseGDMAutoLogin reads gdm's [daemon] keys. Both matter:
// AutomaticLogin names a user even when AutomaticLoginEnable is off, so
// the name alone would warn about autologin that is switched off.
func parseGDMAutoLogin(conf string) string {
	var enabled bool
	var user string
	for _, line := range strings.Split(conf, "\n") {
		line = strings.TrimSpace(line)
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		key, value, found := strings.Cut(line, "=")
		if !found {
			continue
		}
		key = strings.TrimSpace(key)
		value = strings.TrimSpace(value)
		switch strings.ToLower(key) {
		case "automaticloginenable":
			switch strings.ToLower(value) {
			case "true", "yes", "1":
				enabled = true
			}
		case "automaticlogin":
			user = value
		}
	}
	if !enabled || user == "" {
		return ""
	}
	return user
}

// diagConsoleSession returns the id of this user's local seat session,
// or "" when there is none.
func diagConsoleSession(ctx context.Context) string {
	res, err := exec.Capture(ctx, exec.Cmd{
		Name: "loginctl",
		Args: []string{"list-sessions", "--no-legend"},
	})
	if err != nil || res.Failed() {
		return ""
	}
	return seatSessionOf(res.Stdout, vm.DetectIdentity().User)
}

// seatSessionOf finds user's session on a physical seat in `loginctl
// list-sessions --no-legend` output (columns: SESSION UID USER SEAT …).
// A session with no seat ("-") is ssh or systemd-manager and cannot own
// the desktop.
func seatSessionOf(out, user string) string {
	for _, line := range strings.Split(out, "\n") {
		f := strings.Fields(line)
		if len(f) >= 4 && f[2] == user && strings.HasPrefix(f[3], "seat") {
			return f[0]
		}
	}
	return ""
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

// diagData compares intent against reality for everything mpd was asked
// to keep running.
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
		if !entry.Autostart {
			continue
		}
		// Ask the registry for the container name — composing it here
		// would copy the naming rule.
		svc, known := service.Find(entry.Name)
		if !known {
			r.warn("service %q is marked autostart but is not a known service", entry.Name)
			continue
		}
		if d.Podman.Running(ctx, svc.Container()) {
			r.ok("service %s running", entry.Name)
		} else {
			r.fail("service %s is marked autostart but %s is not running", entry.Name, svc.Container())
		}
	}
}

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
