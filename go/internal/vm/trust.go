package vm

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"os"
	"path/filepath"

	"github.com/mutms/mpd/go/internal/exec"
	"github.com/mutms/mpd/go/internal/ui"
)

// TrustCA installs mpd's CA into the system trust store.
//
// Three trust stores need the CA and none share: this one (OpenSSL),
// EnsureCAInUserNSSDB (Chromium family), InstallFirefoxPolicy (Firefox).
// Failures warn rather than abort: an untrusted CA makes browsing noisy,
// not impossible.
func TrustCA(ctx context.Context, out io.Writer, caPath string) {
	if sameFile(caPath, TrustStorePath) {
		ui.OK(out, "CA already installed in system trust store.")
		return
	}

	fmt.Fprintln(out, "Installing the mpd CA into the system trust store (sudo).")
	if code, err := exec.Run(ctx, exec.Cmd{
		Name: "install", Args: []string{"-D", "-m", "644", caPath, TrustStorePath}, Sudo: true,
	}); err != nil || code != 0 {
		ui.Warn(out, "failed to install %s.", TrustStorePath)
		return
	}
	if code, err := exec.Run(ctx, exec.Cmd{
		Name: "update-ca-certificates", Sudo: true,
	}); err != nil || code != 0 {
		ui.Warn(out, "update-ca-certificates failed.")
		return
	}
	ui.OK(out, "CA installed in system trust store.")
}

func sameFile(a, b string) bool {
	da, err := os.ReadFile(a)
	if err != nil {
		return false
	}
	db, err := os.ReadFile(b)
	if err != nil {
		return false
	}
	return bytes.Equal(da, db)
}

// EnsureCAInUserNSSDB imports the CA into ~/.pki/nssdb, which
// Chromium-family browsers read instead of /etc/ssl/certs.
func EnsureCAInUserNSSDB(ctx context.Context, out io.Writer, caPath string) error {
	nssDir := filepath.Join(Home(), ".pki", "nssdb")
	if err := os.MkdirAll(nssDir, 0o755); err != nil {
		return err
	}

	// certutil comes from libnss3-tools; its absence is not worth failing
	// setup over.
	if !exec.Available("certutil") {
		ui.Note(out, "certutil not found (apt: libnss3-tools). Skipping NSS-DB import.")
		return nil
	}

	// `certutil -A` fails on an empty directory, which an account that
	// never started Chromium has.
	if _, err := os.Stat(filepath.Join(nssDir, "cert9.db")); err != nil {
		if code, err := exec.Run(ctx, exec.Cmd{
			Name: "certutil",
			Args: []string{"-N", "--empty-password", "-d", "sql:" + nssDir},
		}); err != nil || code != 0 {
			return fmt.Errorf("certutil failed to initialize NSS DB at %s.", nssDir)
		}
	}

	// `certutil -A` is not idempotent: it fails when the nickname exists,
	// even for identical bytes. Delete-then-add is the supported pattern.
	_, _ = exec.Run(ctx, exec.Cmd{
		Name: "certutil", Args: []string{"-D", "-n", "mpd CA", "-d", "sql:" + nssDir},
	})
	// "C,," trusts the cert as a CA for SSL only.
	if code, err := exec.Run(ctx, exec.Cmd{
		Name: "certutil",
		Args: []string{"-A", "-n", "mpd CA", "-t", "C,,", "-i", caPath, "-d", "sql:" + nssDir},
	}); err != nil || code != 0 {
		return fmt.Errorf("certutil failed to import %s into %s.", caPath, nssDir)
	}
	ui.OK(out, "mpd CA imported into ~/.pki/nssdb/ (restart Chromium-family browsers to apply).")
	return nil
}

// FirefoxPolicy renders the enterprise policy JSON.
//
// Certificates.Install, not ImportEnterpriseRoots: the latter is a no-op
// on Linux. The homepage is set but deliberately not locked.
func FirefoxPolicy(certPath, zone string) (string, error) {
	policy := map[string]any{
		"policies": map[string]any{
			"Certificates": map[string]any{"Install": []string{certPath}},
			"Homepage": map[string]any{
				"URL":       "https://" + zone + "/",
				"Locked":    false,
				"StartPage": "homepage",
			},
		},
	}
	// Go sorts map keys when marshalling, so the bytes are stable and the
	// "already in place" check in InstallFirefoxPolicy is meaningful.
	data, err := json.MarshalIndent(policy, "", "  ")
	if err != nil {
		return "", err
	}
	return string(data) + "\n", nil
}

// firefoxPaths describes where the policy and its cert must land for the
// installed Firefox flavour.
type firefoxPaths struct {
	Dir        string
	Policy     string
	Cert       string
	CopyCert   bool
	FlavorName string
}

// firefoxLayout picks the paths for the installed flavour. firefox-esr
// resolves policies via <install-dir>/distribution/ and reads the system
// trust store; snap confinement cannot, so on the /etc/firefox path the
// cert travels alongside the policy.
func firefoxLayout() firefoxPaths {
	const esrDist = "/usr/lib/firefox-esr/distribution"
	if info, err := os.Stat(esrDist); err == nil && info.IsDir() {
		return firefoxPaths{
			Dir:        esrDist,
			Policy:     esrDist + "/policies.json",
			Cert:       TrustStorePath,
			CopyCert:   false,
			FlavorName: "Firefox-ESR",
		}
	}
	const dir = "/etc/firefox/policies"
	return firefoxPaths{
		Dir:        dir,
		Policy:     dir + "/policies.json",
		Cert:       dir + "/mpd-rootCA.crt",
		CopyCert:   true,
		FlavorName: "Firefox (Mozilla / snap)",
	}
}

// InstallFirefoxPolicy writes the enterprise policy that makes Firefox
// trust the mpd CA. Harmless with no Firefox installed; warns rather
// than fails, like TrustCA.
func InstallFirefoxPolicy(ctx context.Context, out io.Writer, caPath, zone string) {
	p := firefoxLayout()
	policyJSON, err := FirefoxPolicy(p.Cert, zone)
	if err != nil {
		ui.Warn(out, "failed to serialize Firefox policy: %v", err)
		return
	}

	policyCurrent := false
	if existing, err := os.ReadFile(p.Policy); err == nil {
		policyCurrent = string(existing) == policyJSON
	}
	certCurrent := !p.CopyCert || sameFile(caPath, p.Cert)
	if policyCurrent && certCurrent {
		ui.OK(out, "%s enterprise policy already in place at %s.", p.FlavorName, p.Dir)
		return
	}

	staged := filepath.Join(os.TempDir(), "mpd-firefox-policies.json")
	if err := os.WriteFile(staged, []byte(policyJSON), 0o644); err != nil {
		ui.Warn(out, "failed to stage Firefox policy: %v", err)
		return
	}
	defer os.Remove(staged)

	if p.CopyCert {
		// The Mozilla path does not exist until something creates it.
		if _, err := os.Stat(p.Dir); err != nil {
			if code, err := exec.Run(ctx, exec.Cmd{
				Name: "install", Args: []string{"-d", "-m", "755", p.Dir}, Sudo: true,
			}); err != nil || code != 0 {
				ui.Warn(out, "failed to create %s.", p.Dir)
				return
			}
		}
		if code, err := exec.Run(ctx, exec.Cmd{
			Name: "install", Args: []string{"-m", "644", caPath, p.Cert}, Sudo: true,
		}); err != nil || code != 0 {
			ui.Warn(out, "failed to install %s.", p.Cert)
			return
		}
	}

	if code, err := exec.Run(ctx, exec.Cmd{
		Name: "install", Args: []string{"-D", "-m", "644", staged, p.Policy}, Sudo: true,
	}); err != nil || code != 0 {
		ui.Warn(out, "failed to install %s.", p.Policy)
		return
	}
	ui.OK(out, "%s enterprise policy installed at %s.", p.FlavorName, p.Policy)
}
