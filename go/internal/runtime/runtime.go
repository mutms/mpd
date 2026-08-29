// Package runtime creates the one container per VM a developer works
// inside. It runs /sbin/init, so sshd, php-fpm and caddy are real
// services. Provisioning steps live in assets/runtime/bootstrap/; see
// assets/runtime/README.md.
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

	"github.com/mutms/mpd/go/internal/net"
	"github.com/mutms/mpd/go/internal/podman"
)

// Name is the single runtime's canonical name: its state entry, its
// mpd.name/mpd.runtime labels, and the label in runtime.<zone>.
const Name = "runtime"

// Image is the published, pre-baked runtime base (assets/runtime/
// Containerfile). Bump the tag with the one in
// assets/runtime/github-publish.sh.
const Image = "ghcr.io/mutms/mpd-runtime:13.6.2"

// bootstrapDir holds the runtime's provisioning steps, bind-mounted into
// the container at the same path.
const bootstrapDir = "/opt/mpd/assets/runtime/bootstrap"

// PidsLimit caps the runtime's pids cgroup. Podman's default of 2048 is
// exhausted by IDE backends plus agents; see docs/debugging.md.
const PidsLimit = "32768"

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
// On failure the container and its /tmp volume are removed, so the next
// create does not refuse on a runtime that does not work.
func Create(ctx context.Context, out io.Writer, o CreateOptions, p *podman.Client) (string, error) {
	if p.Exists(ctx, o.Container) {
		return "", fmt.Errorf("Runtime already exists.")
	}

	runtimeIP := o.Net.IP(net.HostRuntime)

	if !p.ImageExists(ctx, Image) {
		fmt.Fprintf(out, "\n\033[1m==> Pulling %s\033[0m\n", Image)
		if code, err := p.Pull(ctx, Image); err != nil || code != 0 {
			return "", fmt.Errorf("Failed to pull %s.", Image)
		}
	}

	fmt.Fprintf(out, "\n\033[1m==> Creating runtime\033[0m\n")

	// The control socket's directory must exist, dev-user-owned, before
	// the bind-mount: podman would otherwise create it as root and the
	// daemon could not bind a socket inside it.
	controlDir := podman.ControlDir(Name)
	if err := os.MkdirAll(controlDir, 0o755); err != nil {
		return "", fmt.Errorf("Failed to create %s: %w", controlDir, err)
	}

	// Same reason. 0700: private host keys land here.
	if err := os.MkdirAll(podman.RuntimeSSHDir, 0o700); err != nil {
		return "", fmt.Errorf("Failed to create %s: %w", podman.RuntimeSSHDir, err)
	}

	args := []string{"-d",
		"--name", o.Container,
		"--hostname", o.Container,
		"--network", "mpd-internal:ip=" + runtimeIP,
		"--systemd", "always",
		"--pids-limit", PidsLimit,
		// podman's default AppArmor profile denies the userns_create
		// systemd needs; see docs/debugging.md.
		"--security-opt", "apparmor=unconfined",
	}
	args = append(args, podman.DNSOpts(o.Net.Gateway())...)
	args = append(args, podman.OptMountRO...)
	args = append(args, podman.EnvMountRO...)
	args = append(args, podman.HomeOverrideMountRO...)
	args = append(args, podman.ControlMountRO(Name)...)
	args = append(args, podman.RuntimeSSHMount...)
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
		Image, "/sbin/init",
	)
	if code, err := p.Run(ctx, args); err != nil || code != 0 {
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

	// 50 runs as root: the dev user it creates does not exist yet.
	fmt.Fprintln(out, "\n\033[1m==> Creating the dev user (50-user.sh, root)\033[0m")
	if code, err := p.ExecWithOptions(ctx, o.Container, nil,
		"bash", bootstrapDir+"/50-user.sh",
		Name, o.DevUser, o.UID, o.Net.Zone()); err != nil || code != 0 {
		return "", fmt.Errorf("Runtime step 50-user.sh failed.")
	}

	// 60 and 70 run as the dev user.
	if err := Upgrade(ctx, out, o.Container, o.DevUser, p); err != nil {
		return "", err
	}

	installCA(ctx, out, o.Container, p)

	fmt.Fprintln(out, "\n\033[1m==> Installing SSH public key\033[0m")
	if err := installSSHKey(ctx, o, p); err != nil {
		return "", err
	}

	return runtimeIP, nil
}

// Upgrade brings an existing runtime forward in place: 60 (apt) then 70
// (configuration), both as the dev user. What `mpd --vm-upgrade` runs,
// and the second half of Create.
func Upgrade(ctx context.Context, out io.Writer, container, devUser string, p *podman.Client) error {
	fmt.Fprintf(out, "\n\033[1m==> Installing software (60-install-software.sh)\033[0m\n")
	if code, err := p.ExecAsUser(ctx, container, devUser,
		"bash", bootstrapDir+"/60-install-software.sh"); err != nil || code != 0 {
		return fmt.Errorf("Runtime step 60-install-software.sh failed.")
	}
	return Configure(ctx, out, container, devUser, p)
}

// Configure re-applies the runtime's configuration (70) without apt: what
// `mpd --vm-setup` runs on an existing runtime so asset-level changes
// (units, php.ini, the php dispatcher) reach it.
func Configure(ctx context.Context, out io.Writer, container, devUser string, p *podman.Client) error {
	fmt.Fprintf(out, "\n\033[1m==> Configuring the runtime (70-configure-runtime.sh)\033[0m\n")
	if code, err := p.ExecAsUser(ctx, container, devUser,
		"bash", bootstrapDir+"/70-configure-runtime.sh", Name); err != nil || code != 0 {
		return fmt.Errorf("Runtime step 70-configure-runtime.sh failed.")
	}
	return nil
}

// installCA puts mpd's CA into the runtime's trust store. A failure
// warns rather than aborts: the runtime is usable without it.
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

// installSSHKey authorises the VM's keys inside the runtime: the
// workstation keys from ~/.ssh/authorized_keys, and the VM's own public
// keys so the VM reaches the runtime without agent forwarding.
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
