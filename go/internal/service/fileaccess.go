package service

import (
	"context"
	"fmt"
	"io"
	"os"

	"github.com/mutms/mpd/go/internal/net"
	"github.com/mutms/mpd/go/internal/podman"
	"github.com/mutms/mpd/go/internal/ui"
	"github.com/mutms/mpd/go/internal/vm"
)

// Revision labels let setup tell a container built by an older mpd from
// one built by this mpd. Bump the relevant one whenever a service's
// image, mounts, command or environment change: the label mismatch is
// what makes `--vm-setup` rebuild the container instead of reporting an
// out-of-date one as healthy.
const (
	RevisionLabel      = "mpd.service.revision"
	CAFingerprintLabel = "mpd.ca.fingerprint"

	fileaccessRevision = "9"
	adminerRevision    = "7"
	dnsmasqRevision    = "9"
	// 11: apache.conf is rendered per-VM into <stateDir>/portal/ and
	// mounted from there — the mount source moved, so a surviving
	// container would keep serving `ServerName mpd.test`.
	portalRevision = "11"
)

// Image tags for the services mpd builds rather than pulls.
const (
	FileAccessImage = "localhost/mpd-fileaccess:latest"
	AdminerImage    = "localhost/mpd-adminer:latest"
)

// commonLabels are on every service container: mpd.managed marks it as
// ours to reconcile, and the compose label groups the services together
// in Podman Desktop and `podman ps` output.
func commonLabels(name string) []string {
	return []string{
		"--label", "mpd.managed=true",
		"--label", "mpd.type=service",
		"--label", "mpd.name=" + name,
		"--label", "com.docker.compose.project=mpd-service",
	}
}

// SetupFileAccess creates and starts the fileaccess container.
//
// It must come up before every other setup step, because it is the exec
// target for all data-volume access (Client.Volume*): mpd reaches /srv
// by exec'ing into this container rather than bind-mounting the volume
// on the VM, and `podman exec` into a running container is far cheaper
// per call than `podman run --rm`.
func SetupFileAccess(ctx context.Context, out io.Writer, p *podman.Client, n net.Net, id vm.Identity) error {
	if err := ensureBuiltImage(ctx, out, p, FileAccessImage, "fileaccess"); err != nil {
		return err
	}

	// Persistent host keys, so the SSH fingerprint survives a container
	// rebuild and the developer's known_hosts stays valid.
	if err := os.MkdirAll(vm.FileAccessHostKeysDir, 0o755); err != nil {
		return err
	}

	d, ok := Find("fileaccess")
	if !ok {
		return fmt.Errorf("fileaccess is not in the service registry.")
	}
	p.RemoveIfOutdated(ctx, FileAccessContainer, map[string]string{
		RevisionLabel: fileaccessRevision,
	})

	switch {
	case !p.Exists(ctx, FileAccessContainer):
		args := []string{
			"-d", "--name", FileAccessContainer,
			"--network", "mpd-internal:ip=" + d.IP(n),
			"--restart", "always",
			"-e", "EXTUSER=" + id.User,
			"-e", "EXTUID=" + id.UID,
			"--label", RevisionLabel + "=" + fileaccessRevision,
		}
		args = append(args, commonLabels("fileaccess")...)
		args = append(args, fileAccessMounts(id)...)
		args = append(args, FileAccessImage)
		if code, err := p.Run(ctx, args); err != nil || code != 0 {
			return fmt.Errorf("Failed to create service 'fileaccess'.")
		}
		ui.OK(out, "fileaccess running.")
	case !p.Running(ctx, FileAccessContainer):
		if _, err := p.Start(ctx, FileAccessContainer); err != nil {
			return err
		}
		ui.OK(out, "fileaccess running.")
	default:
		ui.OK(out, "fileaccess already running.")
	}

	ensureDataVolumeDirectories(ctx, p, id.UID)
	return nil
}

// FileAccessContainer is the container name, re-exported from podman so
// callers here do not need both imports.
const FileAccessContainer = podman.FileAccessContainer

// fileAccessMounts gives the container the data volume, its persistent
// host keys, and the VM user's authorized_keys.
//
// The authorized_keys bind is a FILE mount, and podman fails the
// container start with statfs ENOENT if the source does not exist —
// which is why vm.EnsureSSHKey runs before this and guarantees it.
func fileAccessMounts(id vm.Identity) []string {
	args := append([]string{}, podman.OptMountRO...)
	args = append(args,
		"-v", vm.DataVolume+":/srv",
		"-v", vm.FileAccessHostKeysDir+":/etc/ssh/keys",
	)
	home := vm.Home()
	if id.User != "" && home != "" {
		args = append(args, "-v",
			fmt.Sprintf("%s/.ssh/authorized_keys:/home/%s/.ssh/authorized_keys:ro", home, id.User))
	}
	return args
}

// ensureDataVolumeDirectories creates the top-level /srv layout owned by
// the dev user.
//
// entry.sh inside the container does the same thing, but asynchronously
// after `podman run -d` returns — and the very next setup steps write to
// the volume. This explicit exec goes through podman's "wait for the
// container" semantics, so it cannot lose that race. Idempotent with
// entry.sh; keep the directory list in sync with it.
//
// Runs as root inside the container so it can chown out from under
// whatever ownership a pre-existing volume came with.
func ensureDataVolumeDirectories(ctx context.Context, p *podman.Client, uid string) {
	if uid == "" {
		return
	}
	cmd := append([]string{"install", "-d", "-o", uid, "-g", uid, "-m", "0775"},
		"/srv/projects", "/srv/data", "/srv/meta", "/srv/dbs", "/srv/backups")
	_, _ = p.ExecWithOptions(ctx, FileAccessContainer, []string{"--user", "0:0"}, cmd...)
}

// ensureBuiltImage builds a service image from its assets directory if
// it is not already present.
func ensureBuiltImage(ctx context.Context, out io.Writer, p *podman.Client, tag, name string) error {
	if p.ImageExists(ctx, tag) {
		return nil
	}
	contextDir := vm.AssetsDir + "/services/" + name
	ui.Step(out, "Building %s image", name)
	if code, err := p.BuildImage(ctx, tag, contextDir); err != nil || code != 0 {
		return fmt.Errorf("Failed to build %s image from %s.", name, contextDir)
	}
	return nil
}
