// Package vm holds the operations mpd performs on the VM itself, as
// opposed to on containers.
//
// Everything here touches host state: /etc, the system trust store, the
// dev user's home directory, systemd. It is the half of `mpd --vm-setup`
// that podman knows nothing about. Container-side setup lives in
// internal/service.
//
// Paths are absolute and VM-wide rather than derived from $HOME: the mpd
// VM is a single-purpose appliance, so code, assets and state live in
// FHS-standard system locations and the dev user simply owns them.
package vm

import (
	"context"
	"fmt"
	"os"
	"os/user"
	"strings"

	"github.com/mutms/mpd/go/internal/exec"
)

// Fixed VM-wide paths. See AGENTS.md §"Fixed in-VM paths".
const (
	// MpdDir is the git checkout: code, assets, built binary.
	MpdDir = "/opt/mpd"
	// AssetsDir is bind-mounted read-only into every mpd container at
	// this same path, so asset lookups resolve identically either side.
	AssetsDir = MpdDir + "/assets"
	// BinDir holds the built binary.
	BinDir = MpdDir + "/bin"

	// VarLibDir is the persistent state root.
	VarLibDir = "/var/lib/mpd"
	// ConfDir holds the CA, the service cert and platform.env. PRIVATE —
	// never bind-mounted into a container.
	ConfDir = VarLibDir + "/conf"
	// EnvDir holds mpd-vm.env, the user's VM-wide overrides.
	EnvDir = VarLibDir + "/env"
	// SkelDir holds user-managed dotfiles overlaid onto new runtimes.
	SkelDir = VarLibDir + "/skel"
	// StateDir holds mpd-managed operational state.
	StateDir = VarLibDir + "/state"

	// CARootDir holds the local CA. ServiceDir holds the cert the portal
	// serves the zone apex with. TempDir is openssl scratch space.
	CARootDir  = ConfDir + "/caroot"
	ServiceDir = ConfDir + "/service"
	TempDir    = ConfDir + "/temp"

	// DNSHostsDir holds the hosts files dnsmasq serves mpd's names from.
	// dnsmasq watches the directory and re-reads it on every add, change
	// and remove, so a record lands without signalling or restarting it.
	DNSHostsDir = StateDir + "/dns"
	// DnsmasqConfPath is the resolver's configuration, rendered by
	// --vm-setup. Under ConfDir with the CA rather than under StateDir:
	// it is mpd's own configuration of the VM, not operational state, and
	// nothing rebuilds it from observation.
	DnsmasqConfPath = ConfDir + "/dnsmasq.conf"
	// CACertPath is the trust anchor: the certificate every trust store on
	// this VM is told about. CAKeyPath is its private key, which is present
	// only on VMs that sign with the anchor directly — see SigningCertPath.
	CACertPath = CARootDir + "/rootCA.pem"
	CAKeyPath  = CARootDir + "/rootCA-key.pem"

	// SigningCertPath and SigningKeyPath are the CA this VM actually signs
	// leaf certificates with, which is not necessarily the anchor.
	//
	// A VM provisioned by mpd-virt gets an intermediate constrained to its
	// own zone (`permitted;DNS:<NNN>.mpd.test`) and never sees the root's
	// private key at all, so a compromised VM can mint certificates for its
	// own names and nothing else. A VM set up by setup/linux or
	// setup/windows generates a self-signed CA and writes it to both paths,
	// making anchor and signer the same certificate and the chain one long.
	//
	// cert.Signer resolves which case a given VM is in.
	SigningCertPath = CARootDir + "/vmCA.pem"
	SigningKeyPath  = CARootDir + "/vmCA-key.pem"

	// LanHostsPath holds names for machines on the local network that are
	// not mpd VMs, in hosts(5) format, pushed in by `mpd-virt server sync`.
	// Under ConfDir rather than StateDir: it is configuration handed to
	// this VM from outside, not state the VM derives or rebuilds.
	LanHostsPath = ConfDir + "/lan-hosts"

	// TrustStorePath is where the CA lands in the system trust store.
	TrustStorePath = "/usr/local/share/ca-certificates/mpd-local.crt"

	// BinaryPath is the installed binary, hardcoded into the rendered
	// systemd unit so `cat mpd.service` shows the real path.
	BinaryPath = BinDir + "/mpd"

	// Label names the execution environment in setup output.
	Label = "mpd VM (Debian Trixie)"
)

// DataVolume is the podman volume holding /srv inside every container.
const DataVolume = "mpd-data-volume"

// Identity is the dev user mpd runs as and provisions containers for.
type Identity struct {
	User string
	UID  string
}

// DetectIdentity reports the invoking user. mpd always runs as the dev
// user (never root, never via sudo -u — see AGENTS.md §"Mandatory
// privilege rule"), so this is simply who we are.
func DetectIdentity() Identity {
	id := Identity{UID: fmt.Sprint(os.Getuid())}
	if u, err := user.Current(); err == nil {
		id.User = u.Username
	}
	return id
}

// Home is the dev user's home directory. Used only for genuinely
// per-user concerns — SSH keys, shell config, systemd user units.
// Nothing mpd-owned lives here.
func Home() string {
	if h, err := os.UserHomeDir(); err == nil {
		return h
	}
	return ""
}

// AssetsPath returns the assets directory, failing loudly if the
// checkout looks incomplete rather than letting a missing path surface
// later as a confusing container error.
func AssetsPath() (string, error) {
	if _, err := os.Stat(AssetsDir + "/runtime-base"); err != nil {
		return "", fmt.Errorf("Assets not found at %s — clone mpd to /opt/mpd.", AssetsDir)
	}
	return AssetsDir, nil
}

// Fingerprint is a short content hash of a file, used as a container
// label so a changed CA forces the service containers that embedded it
// to be rebuilt. Empty for a missing or unreadable file, which callers
// treat as "no opinion" rather than as a mismatch.
//
// 16 hex characters of SHA-256: this is a change detector, not a
// security boundary, and a label that fits on one line is easier to read
// in `podman inspect`.
func Fingerprint(ctx context.Context, path string) string {
	if _, err := os.Stat(path); err != nil {
		return ""
	}
	res, err := exec.Capture(ctx, exec.Cmd{Name: "sha256sum", Args: []string{path}})
	if err != nil || res.Code != 0 {
		return ""
	}
	hex, _, _ := strings.Cut(res.Stdout, " ")
	if len(hex) < 16 {
		return ""
	}
	return hex[:16]
}

// EnsureDir creates a directory (and parents) with the given mode,
// refusing when the path exists as something other than a directory —
// a symlink or stray file there would otherwise fail much later, inside
// a container, with a far less obvious message.
func EnsureDir(path string, mode os.FileMode) error {
	if info, err := os.Stat(path); err == nil {
		if !info.IsDir() {
			return fmt.Errorf("Path exists but is not a directory: %s", path)
		}
		return os.Chmod(path, mode)
	}
	if err := os.MkdirAll(path, mode); err != nil {
		return err
	}
	return os.Chmod(path, mode)
}
