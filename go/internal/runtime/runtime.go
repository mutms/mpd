// Package runtime creates the containers a developer works inside.
//
// A runtime is a pod plus a systemd main container: the pod owns the
// address and the shared namespaces, the container runs /sbin/init so
// sshd, php-fpm and friends are real services rather than PID 1
// impersonators. Sidecars join the same pod.
//
// Provisioning is two-phase, and the split is a privilege boundary, not
// a convenience (AGENTS.md §"Mandatory privilege rule"):
//
//	phase 1  bootstrap.sh  as root      — creates the dev user, lays out /srv
//	phase 2  build.sh      as dev user  — installs the runtime's own stack
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
	"regexp"
	"sort"
	"strings"
	"time"

	"github.com/mutms/mpd/go/internal/assets"
	"github.com/mutms/mpd/go/internal/net"
	"github.com/mutms/mpd/go/internal/podman"
)

// BaseImage is the shared systemd-enabled Debian image every runtime is
// built from.
const BaseImage = "mpd-debian-trixie-systemd"

// TmpVolume is the disk-backed /tmp for a runtime pod.
func TmpVolume(pod string) string { return pod + "-tmp" }

var validName = regexp.MustCompile(`^[a-z][a-z0-9]+$`)

// ValidateName checks the runtime name shape and that assets define it.
//
// Two separate checks with different messages: a malformed name is a
// typo, whereas a well-formed name with no assets is a request for a
// runtime that does not exist — and the fix for that is to write its
// build.sh.
func ValidateName(name string, a assets.Tree) error {
	if !validName.MatchString(name) {
		return fmt.Errorf("'%s' is not a valid runtime name. "+
			"Use lowercase letters and digits only, starting with a letter, minimum 2 characters.", name)
	}
	known := a.RuntimeNames()
	for _, n := range known {
		if n == name {
			return nil
		}
	}
	sort.Strings(known)
	return fmt.Errorf("No runtime definition found for '%s' in assets/runtimes/.\n"+
		"Available runtimes: %s\n"+
		"To add a new runtime, create assets/runtimes/%s/build.sh",
		name, strings.Join(known, ", "), name)
}

// CreateOptions carries what Create needs from the caller.
type CreateOptions struct {
	Name      string
	Pod       string
	Container string
	DevUser   string
	UID       string
	Home      string
	Net       net.Net
	Assets    assets.Tree
}

// Create builds and provisions a runtime, leaving it running.
//
// On failure after the pod exists, the pod and its /tmp volume are
// removed: a half-created runtime is worse than none, because the next
// create would refuse on "already exists" while the thing does not work.
func Create(ctx context.Context, out io.Writer, o CreateOptions, p *podman.Client) (string, error) {
	if err := ValidateName(o.Name, o.Assets); err != nil {
		return "", err
	}
	if p.Exists(ctx, o.Container) {
		return "", fmt.Errorf("Runtime '%s' already exists.", o.Name)
	}

	cfg, ok := o.Assets.RuntimeConfig(o.Name)
	if !ok {
		return "", fmt.Errorf("Runtime '%s' has no configuration.json in assets/runtimes/.", o.Name)
	}
	if cfg.IPOctet < net.FirstRuntimeHost || cfg.IPOctet > 254 {
		return "", fmt.Errorf("Runtime '%s' configuration.json has ipOctet=%d; runtimes live at %d–254.",
			o.Name, cfg.IPOctet, net.FirstRuntimeHost)
	}
	runtimeIP := o.Net.IP(cfg.IPOctet)

	if !p.ImageExists(ctx, BaseImage) {
		fmt.Fprintf(out, "\n\033[1m==> Building base image '%s'\033[0m\n", BaseImage)
		if code, err := p.BuildImage(ctx, BaseImage, assets.Dir+"/runtime-base", nil); err != nil || code != 0 {
			return "", fmt.Errorf("Failed to build base image '%s'.", BaseImage)
		}
	}

	fmt.Fprintf(out, "\n\033[1m==> Creating runtime '%s'\033[0m\n", o.Name)

	// Pod hostname matches the pod name, so bash's default \h prompt
	// names the VM when SSH'd in. Set on the pod because members share
	// the UTS namespace.
	//
	// --shm-size: pod members share the infra container's /dev/shm.
	// Chromium (Behat's selenium sidecar) maps renderer shared memory
	// there and crashes on the default 64 MB. tmpfs is a cap, not a
	// reservation, so idle pods cost nothing — safe for every runtime.
	//
	// No --dns here: the network carries it (see the podman network
	// created by --vm-setup), and every attached container inherits it.
	if code, err := p.PodCreate(ctx, []string{
		"--name", o.Pod,
		"--hostname", o.Pod,
		"--network", "mpd-internal:ip=" + runtimeIP,
		"--shm-size=2g",
		"--label", "com.docker.compose.project=mpd-dev",
	}); err != nil || code != 0 {
		return "", fmt.Errorf("Failed to create runtime '%s'.", o.Name)
	}

	args := []string{"-d", "--name", o.Container, "--pod", o.Pod, "--systemd", "always"}
	args = append(args, podman.OptMountRO...)
	args = append(args, podman.EnvMountRO...)
	args = append(args, podman.SkelMountRO...)
	if podman.MudevPresent() {
		args = append(args, podman.MudevMountRO...)
	}
	args = append(args,
		"-v", "mpd-data-volume:/srv",
		// Explicit disk-backed /tmp. Without it, --systemd mode makes
		// podman mount a RAM-backed tmpfs there.
		"-v", TmpVolume(o.Pod)+":/tmp",
		"--label", "mpd.managed=true",
		"--label", "mpd.name="+o.Name,
		"--label", "mpd.runtime="+o.Name,
		"--label", "mpd.ip="+runtimeIP,
		"--label", "com.docker.compose.project=mpd-dev",
		BaseImage, "/sbin/init",
	)
	if code, err := p.Run(ctx, args); err != nil || code != 0 {
		// Roll back, or the next create refuses on a runtime that does
		// not work.
		_, _ = p.PodRemove(ctx, o.Pod)
		_, _ = p.VolumeRemove(ctx, TmpVolume(o.Pod))
		return "", fmt.Errorf("Failed to create main container.")
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
	fmt.Fprintln(out, "\n\033[1m==> Bootstrapping runtime base\033[0m")
	if code, err := p.ExecWithOptions(ctx, o.Container, nil,
		"bash", "/opt/mpd/assets/runtime-base/bootstrap.sh",
		o.Name, o.DevUser, o.UID, o.Net.Zone()); err != nil || code != 0 {
		return "", fmt.Errorf("Runtime '%s' base bootstrap failed.", o.Name)
	}

	// Phase 2 — dev user. Everything from here runs unprivileged.
	fmt.Fprintf(out, "\n\033[1m==> Building '%s' runtime\033[0m\n", o.Name)
	if code, err := p.ExecAsUser(ctx, o.Container, o.DevUser,
		"bash", "/opt/mpd/assets/runtimes/"+o.Name+"/build.sh", o.Name); err != nil || code != 0 {
		return "", fmt.Errorf("Runtime '%s' build failed.", o.Name)
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
