// Package runtime creates the container a developer works inside.
//
// There is exactly one runtime per VM: a plain systemd container (no
// pod) at net.HostRuntime, running /sbin/init so sshd, php-fpm, caddy
// and friends are real services rather than PID 1 impersonators. TLS
// for project URLs terminates inside it (mpd-caddy.service, installed
// by build.sh).
//
// Provisioning is two-phase, and the split is a privilege boundary, not
// a convenience (AGENTS.md §"Mandatory privilege rule"):
//
//	phase 1  bootstrap.sh  as root      — creates the dev user, lays out /srv
//	phase 2  build.sh      as dev user  — installs the language stacks + caddy
//
// bootstrap.sh is the single sanctioned root-context script in mpd,
// because the user it creates cannot exist before it runs.
package runtime

import (
	"context"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"time"

	"github.com/mutms/mpd/go/internal/assets"
	"github.com/mutms/mpd/go/internal/net"
	"github.com/mutms/mpd/go/internal/podman"
)

// Name is the single runtime's canonical name: its state entry, its
// mpd.name/mpd.runtime labels, and the label in runtime.<zone>.
const Name = "runtime"

// BaseImage is the systemd-enabled Debian image the runtime is built
// from.
const BaseImage = "mpd-debian-trixie-systemd"

// TmpVolume is the disk-backed /tmp volume for the runtime container.
func TmpVolume(container string) string { return container + "-tmp" }

// CreateOptions carries what Create needs from the caller.
type CreateOptions struct {
	Container string
	DevUser   string
	UID       string
	Home      string
	Net       net.Net
}

// Create builds and provisions the runtime, leaving it running.
//
// On failure after the container exists, the container and its /tmp
// volume are removed: a half-created runtime is worse than none, because
// the next create would refuse on "already exists" while the thing does
// not work.
func Create(ctx context.Context, out io.Writer, o CreateOptions, p *podman.Client) (string, error) {
	if p.Exists(ctx, o.Container) {
		return "", fmt.Errorf("Runtime already exists.")
	}

	runtimeIP := o.Net.IP(net.HostRuntime)

	if !p.ImageExists(ctx, BaseImage) {
		fmt.Fprintf(out, "\n\033[1m==> Building base image '%s'\033[0m\n", BaseImage)
		if code, err := p.BuildImage(ctx, BaseImage, assets.Dir+"/runtime", nil); err != nil || code != 0 {
			return "", fmt.Errorf("Failed to build base image '%s'.", BaseImage)
		}
	}

	fmt.Fprintf(out, "\n\033[1m==> Creating runtime\033[0m\n")

	// The control socket's directory must exist, and be dev-user-owned,
	// before podman is asked to bind-mount it: podman would otherwise
	// create it as root and the daemon could not bind a socket inside it.
	// Created here rather than by the daemon because the mount is
	// established now, at container create, and the daemon may not have
	// started yet on a freshly set-up VM.
	controlDir := podman.ControlDir(Name)
	if err := os.MkdirAll(controlDir, 0o755); err != nil {
		return "", fmt.Errorf("Failed to create %s: %w", controlDir, err)
	}

	// Container hostname matches its name. The prompt the developer sees
	// is not this string: the skel .bashrc rewrites `\h` to `mpd-<NNN>`,
	// the host-side alias that reaches this container.
	args := []string{"-d",
		"--name", o.Container,
		"--hostname", o.Container,
		"--network", "mpd-internal:ip=" + runtimeIP,
		"--systemd", "always",
	}
	args = append(args, podman.DNSOpts(o.Net.Gateway())...)
	args = append(args, podman.OptMountRO...)
	args = append(args, podman.EnvMountRO...)
	args = append(args, podman.SkelMountRO...)
	args = append(args, podman.ControlMountRO(Name)...)
	if podman.MudevPresent() {
		args = append(args, podman.MudevMountRO...)
	}
	args = append(args,
		"-v", "mpd-data-volume:/srv",
		// Explicit disk-backed /tmp. Without it, --systemd mode makes
		// podman mount a RAM-backed tmpfs there.
		"-v", TmpVolume(o.Container)+":/tmp",
		"--label", "mpd.managed=true",
		"--label", "mpd.name="+Name,
		"--label", "mpd.runtime="+Name,
		"--label", "mpd.ip="+runtimeIP,
		"--label", "com.docker.compose.project=mpd-dev",
		BaseImage, "/sbin/init",
	)
	if code, err := p.Run(ctx, args); err != nil || code != 0 {
		// Roll back, or the next create refuses on a runtime that does
		// not work.
		_, _ = p.Remove(ctx, o.Container)
		_, _ = p.VolumeRemove(ctx, TmpVolume(o.Container))
		return "", fmt.Errorf("Failed to create runtime container.")
	}

	fmt.Fprintln(out, "Waiting for systemd to initialise...")
	for i := 0; i < 30; i++ {
		time.Sleep(time.Second)
		res, err := p.ExecCapture(ctx, o.Container, "systemctl", "is-system-running")
		if err == nil && (res.Stdout == "running" || res.Stdout == "degraded") {
			break
		}
	}

	// Phase 1 — root. The one sanctioned root-context script: the dev
	// user does not exist yet, so nothing else could create it.
	fmt.Fprintln(out, "\n\033[1m==> Bootstrapping the runtime (phase 1, root)\033[0m")
	if code, err := p.ExecWithOptions(ctx, o.Container, nil,
		"bash", "/opt/mpd/assets/runtime/bootstrap.sh",
		Name, o.DevUser, o.UID, o.Net.Zone()); err != nil || code != 0 {
		return "", fmt.Errorf("Runtime bootstrap (phase 1) failed.")
	}

	// Phase 2 — dev user. Everything from here runs unprivileged.
	fmt.Fprintf(out, "\n\033[1m==> Building the runtime\033[0m\n")
	if code, err := p.ExecAsUser(ctx, o.Container, o.DevUser,
		"bash", "/opt/mpd/assets/"+assets.RuntimeDir+"/build.sh", Name); err != nil || code != 0 {
		return "", fmt.Errorf("Runtime build failed.")
	}

	installCA(ctx, out, o.Container, p)

	fmt.Fprintln(out, "\n\033[1m==> Installing SSH public key\033[0m")
	if err := installSSHKey(ctx, o, p); err != nil {
		return "", err
	}

	return runtimeIP, nil
}

// installCA puts mpd's CA into the runtime's trust store so `curl
// https://<project>.<zone>/` works inside the container without
// --insecure. A failure warns rather than aborts: the runtime is usable
// without it, just noisier.
func installCA(ctx context.Context, out io.Writer, container string, p *podman.Client) {
	caPath := "/var/lib/mpd/conf/caroot/rootCA.pem"
	if _, err := os.Stat(caPath); err != nil {
		return
	}
	code, err := p.Copy(ctx, caPath, container+":/usr/local/share/ca-certificates/mpd-local.crt")
	if err != nil || code != 0 {
		fmt.Fprintln(out, "Warning: failed to install CA cert into runtime.")
		return
	}
	if c := p.ExecQuietly(ctx, container, "update-ca-certificates"); c != 0 {
		fmt.Fprintln(out, "Warning: failed to install CA cert into runtime.")
	}
}

// installSSHKey authorises the VM's keys inside the runtime.
//
// Both the forwarded/laptop keys (~/.ssh/authorized_keys) and the VM's
// own public keys are installed: the first lets the developer SSH in
// from the workstation, the second lets the VM itself reach the runtime
// without agent forwarding.
func installSSHKey(ctx context.Context, o CreateOptions, p *podman.Client) error {
	keys := AuthorizedPublicKeys(o.Home)
	if len(keys) == 0 {
		return fmt.Errorf("No SSH public keys found for runtime authorization.")
	}
	body := strings.Join(keys, "\n") + "\n"

	sshDir := "/home/" + o.DevUser + "/.ssh"
	if code := p.ExecQuietly(ctx, o.Container, "mkdir", "-p", sshDir); code != 0 {
		return fmt.Errorf("Failed to create %s in runtime.", sshDir)
	}
	tmp, err := os.CreateTemp("", "mpd-authorized-keys")
	if err != nil {
		return err
	}
	defer os.Remove(tmp.Name())
	if _, err := tmp.WriteString(body); err != nil {
		tmp.Close()
		return err
	}
	tmp.Close()

	if code, err := p.Copy(ctx, tmp.Name(), o.Container+":"+sshDir+"/authorized_keys"); err != nil || code != 0 {
		return fmt.Errorf("Failed to install authorized_keys into runtime.")
	}
	p.ExecQuietly(ctx, o.Container, "chmod", "700", sshDir)
	p.ExecQuietly(ctx, o.Container, "chmod", "600", sshDir+"/authorized_keys")
	p.ExecQuietly(ctx, o.Container, "chown", "-R", o.DevUser+":"+o.DevUser, sshDir)
	return nil
}

// AuthorizedPublicKeys collects the keys a runtime should trust, deduped
// and order-stable: the VM's own authorized_keys first, then its
// id_*.pub.
func AuthorizedPublicKeys(home string) []string {
	var out []string
	seen := map[string]bool{}

	add := func(line string) {
		line = strings.TrimSpace(line)
		if line == "" || strings.HasPrefix(line, "#") || seen[line] {
			return
		}
		seen[line] = true
		out = append(out, line)
	}

	if data, err := os.ReadFile(filepath.Join(home, ".ssh", "authorized_keys")); err == nil {
		for _, line := range strings.Split(string(data), "\n") {
			add(line)
		}
	}
	entries, err := os.ReadDir(filepath.Join(home, ".ssh"))
	if err != nil {
		return out
	}
	var names []string
	for _, e := range entries {
		if strings.HasPrefix(e.Name(), "id_") && strings.HasSuffix(e.Name(), ".pub") {
			names = append(names, e.Name())
		}
	}
	sort.Strings(names)
	for _, n := range names {
		if data, err := os.ReadFile(filepath.Join(home, ".ssh", n)); err == nil {
			add(string(data))
		}
	}
	return out
}
