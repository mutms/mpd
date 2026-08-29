// Package vm holds the operations mpd performs on the VM itself, as
// opposed to on containers. Everything here touches host state: /etc,
// the trust stores, the dev user's home, systemd.
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
	// ConfDir holds the CA and the service cert. PRIVATE — never
	// bind-mounted into a container.
	ConfDir = VarLibDir + "/conf"
	// EnvDir holds the developer's own env — vm.env (VM shells) and
	// runtime.env (runtimes) — pushed in from the Mac by mpd-virt.
	EnvDir = VarLibDir + "/env"
	// HomeOverrideDir holds user-managed dotfiles overlaid onto new runtimes'
	// home, on top of the shipped assets/runtime/home defaults.
	HomeOverrideDir = VarLibDir + "/home"
	// StateDir holds mpd-managed operational state.
	StateDir = VarLibDir + "/state"

	// CARootDir holds the local CA. ServiceDir holds the cert the portal
	// serves the zone apex with. TempDir is openssl scratch space.
	CARootDir  = ConfDir + "/caroot"
	ServiceDir = ConfDir + "/service"
	TempDir    = ConfDir + "/temp"

	// DnsmasqConfPath is the resolver's configuration. Under ConfDir, not
	// StateDir: it is mpd's configuration of the VM, not operational state.
	DnsmasqConfPath = ConfDir + "/dnsmasq.conf"
	// CACertPath is the trust anchor: the certificate every trust store on
	// this VM is told about. CAKeyPath is its private key, which is present
	// only on VMs that sign with the anchor directly — see SigningCertPath.
	CACertPath = CARootDir + "/rootCA.pem"
	CAKeyPath  = CARootDir + "/rootCA-key.pem"

	// SigningCertPath and SigningKeyPath are the CA this VM signs leaf
	// certificates with — not necessarily the anchor; see
	// docs/security.md. cert.Signer resolves which case a VM is in.
	SigningCertPath = CARootDir + "/vmCA.pem"
	SigningKeyPath  = CARootDir + "/vmCA-key.pem"

	// LanHostsPath holds hosts(5) names for non-mpd machines on the LAN,
	// pushed in by `mpd-virt server sync`.
	LanHostsPath = ConfDir + "/lan-hosts"

	// TrustStorePath is where the CA lands in the system trust store.
	TrustStorePath = "/usr/local/share/ca-certificates/mpd-local.crt"

	// BinaryPath is the installed binary, hardcoded into the rendered
	// systemd units.
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

// DetectIdentity reports the invoking user; mpd always runs as the dev
// user (see AGENTS.md, "Mandatory privilege rule").
func DetectIdentity() Identity {
	id := Identity{UID: fmt.Sprint(os.Getuid())}
	if u, err := user.Current(); err == nil {
		id.User = u.Username
	}
	return id
}

// Home is the dev user's home directory; nothing mpd-owned lives here.
func Home() string {
	if h, err := os.UserHomeDir(); err == nil {
		return h
	}
	return ""
}

// AssetsPath returns the assets directory, failing loudly when the
// checkout looks incomplete.
func AssetsPath() (string, error) {
	if _, err := os.Stat(AssetsDir + "/runtime"); err != nil {
		return "", fmt.Errorf("Assets not found at %s — clone mpd to /opt/mpd.", AssetsDir)
	}
	return AssetsDir, nil
}

// Fingerprint is a short content hash of a file, used as a container
// label so a changed CA forces dependent containers to rebuild. Empty
// for an unreadable file, which callers treat as "no opinion". 16 hex
// characters: a change detector, not a security boundary.
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
// refusing a path that exists as something other than a directory.
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
