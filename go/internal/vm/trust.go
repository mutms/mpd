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
// Three trust stores need it and none of them share: this one covers
// curl, wget and anything using OpenSSL; EnsureCAInUserNSSDB covers the
// Chromium family; InstallFirefoxPolicy covers Firefox. Missing any one
// of them shows up as a certificate warning in exactly one program,
// which is a confusing thing to debug.
//
// Failures warn rather than abort: an untrusted CA makes browsing noisy,
// not impossible, and setup has more useful work left to do.
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

// EnsureCAInUserNSSDB imports the CA into ~/.pki/nssdb.
//
// Chromium-family browsers on Linux read SSL trust from this database,
// not from /etc/ssl/certs — so without this step the portal shows a
// security warning even though the OS trust store has the CA.
func EnsureCAInUserNSSDB(ctx context.Context, out io.Writer, caPath string) error {
	nssDir := filepath.Join(Home(), ".pki", "nssdb")
	if err := os.MkdirAll(nssDir, 0o755); err != nil {
		return err
	}

	// certutil comes from libnss3-tools. Not worth failing setup over:
	// the user can accept the warning by hand until they install it.
	if !exec.Available("certutil") {
		ui.Note(out, "certutil not found (apt: libnss3-tools). Skipping NSS-DB import.")
		return nil
	}

	// `certutil -A` needs an existing cert9.db/key4.db pair and fails on
	// an empty directory — which is what a dev account that has never
	// started Chromium has.
	if _, err := os.Stat(filepath.Join(nssDir, "cert9.db")); err != nil {
		if code, err := exec.Run(ctx, exec.Cmd{
			Name: "certutil",
			Args: []string{"-N", "--empty-password", "-d", "sql:" + nssDir},
		}); err != nil || code != 0 {
			return fmt.Errorf("certutil failed to initialize NSS DB at %s.", nssDir)
		}
	}

	// `certutil -A` is NOT idempotent: it fails with
	// SEC_ERROR_ADDING_CERT when the nickname already exists, even for
	// identical bytes. Delete-then-add is the supported pattern; the
	// delete errors harmlessly on the first run.
	_, _ = exec.Run(ctx, exec.Cmd{
		Name: "certutil", Args: []string{"-D", "-n", "mpd CA", "-d", "sql:" + nssDir},
	})
	// "C,," trusts the cert as a CA for SSL only — not for email or
	// code signing, which mpd has no business vouching for.
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
// `Certificates.Install` rather than `ImportEnterpriseRoots`: the latter
// is a no-op on Linux (Mozilla's Linux build has no p11-kit path), while
// Install loads PEM files into NSS directly.
//
// The homepage is set but deliberately not locked — the portal is the
// useful default landing page, and a developer who prefers their own
// Moodle should be able to say so.
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
	// Go sorts map keys when marshalling, so the bytes are stable — which
	// is what makes the "already in place" check in InstallFirefoxPolicy
	// meaningful rather than a coin flip.
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

// firefoxLayout picks the paths for the installed flavour.
//
// Debian Trixie's firefox-esr resolves policies via XREAppDist, which on
// Linux is <install-dir>/distribution/, and it can read the system trust
// store copy of the CA. Everything else (Mozilla deb, snap) uses the
// documented /etc/firefox/policies/ path — and snap confinement permits
// that directory but generally not /usr/local/share/ca-certificates, so
// there the cert has to travel alongside the policy.
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
// trust the mpd CA. Harmless when no Firefox is installed; warns rather
// than fails, for the same reason TrustCA does.
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
		// The firefox-esr package owns its directory; the Mozilla path
		// does not exist until something creates it.
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
