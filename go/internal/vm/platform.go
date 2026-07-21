package vm

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"
)

// PlatformEnvPath is the in-VM identity file. It records which kind of
// mpd install this is and which VM it is, and is read by everything that
// composes an address or a name.
const PlatformEnvPath = ConfDir + "/platform.env"

// PlatformKind distinguishes the two user-facing modes.
const (
	// PlatformManaged is a VM driven by the host-side mpd-virt
	// orchestrator; the user stays on their workstation.
	PlatformManaged = "managed"
	// PlatformSandbox is a desktop-inside-the-VM install; the user
	// lives in the VM.
	PlatformSandbox = "sandbox"
)

// PlatformIdentity is the content of platform.env that mpd owns.
type PlatformIdentity struct {
	// Platform is "managed" or "sandbox".
	Platform string
	// VMIP is the VM's static address, empty on sandbox (DHCP).
	VMIP string
	// VMID is the 3-digit identifier every name and address derives
	// from: "100"–"254" for managed VMs, "000" for the sandbox.
	VMID string
}

// managedKeys are the keys this writer owns. Everything else in the file
// — MPD_NETWORK_* written by a bootstrap script, say — is preserved
// verbatim, so the bootstrap scripts and mpd can share one file without
// clobbering each other.
var managedKeys = map[string]bool{
	"MPD_PLATFORM": true, "MPD_VM_IP": true, "MPD_VM_ID": true,
}

// LoadPlatform reads the VM's own platform.env.
func LoadPlatform() (PlatformIdentity, error) { return LoadPlatformFrom(PlatformEnvPath) }

// LoadPlatformFrom reads a platform.env at an explicit path, failing
// with the bootstrap command that creates it when it is absent.
func LoadPlatformFrom(path string) (PlatformIdentity, error) {
	body, err := os.ReadFile(path)
	if err != nil {
		return PlatformIdentity{}, fmt.Errorf("Missing %s.\n"+
			"Run the matching bootstrap first:\n"+
			"  • sandbox VM:  setup/sandbox/take-over-sandbox-vm.sh\n"+
			"  • managed VM:  the host-side `mpd-virt` orchestrator", path)
	}
	kv := parseEnv(string(body))
	platform := kv["MPD_PLATFORM"]
	if platform != PlatformManaged && platform != PlatformSandbox {
		return PlatformIdentity{}, fmt.Errorf(
			"%s: MPD_PLATFORM missing or invalid (expected: managed, sandbox).", path)
	}
	return PlatformIdentity{
		Platform: platform,
		VMIP:     kv["MPD_VM_IP"],
		VMID:     kv["MPD_VM_ID"],
	}, nil
}

// WritePlatform rewrites the VM's own platform.env.
func WritePlatform(id PlatformIdentity) error { return WritePlatformTo(PlatformEnvPath, id) }

// WritePlatformTo rewrites the managed keys at an explicit path and
// preserves every other line verbatim.
func WritePlatformTo(path string, id PlatformIdentity) error {
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		return err
	}

	var preserved []string
	if body, err := os.ReadFile(path); err == nil {
		for _, raw := range strings.Split(string(body), "\n") {
			line := strings.TrimSpace(raw)
			if line == "" || strings.HasPrefix(line, "#") {
				continue
			}
			key, _, found := strings.Cut(line, "=")
			if !found || managedKeys[key] {
				continue
			}
			preserved = append(preserved, line)
		}
	}

	body := "# mpd platform identity — written by setup, read at runtime.\n" +
		"# Lives under /var/lib/mpd/conf/.\n" +
		"MPD_PLATFORM=" + id.Platform + "\n" +
		"MPD_VM_IP=" + id.VMIP + "\n" +
		"# 3-digit VM identifier used in pod/container/hostname names.\n" +
		"# Auto-derived from the VM hostname (mpd-<NNN>) at --vm-setup; edit\n" +
		"# to override. Runtime containers are named mpd-<NNN>-<runtime>.\n" +
		"MPD_VM_ID=" + id.VMID + "\n"
	if len(preserved) > 0 {
		body += "\n# Other keys preserved verbatim (set by bootstrap scripts):\n" +
			strings.Join(preserved, "\n") + "\n"
	}
	return os.WriteFile(path, []byte(body), 0o644)
}

// DeriveVMID reads the 3-digit VM identifier out of the VM's hostname.
//
// The hostname is the authority, not platform.env: it is what the
// hypervisor-side bootstrap set, it is what the user sees in their
// prompt, and a VM cloned to a new identity gets a new hostname. `mpd
// --vm-setup` re-derives on every run and writes the result back, so a
// hand-edited MPD_VM_ID survives only until the next setup.
//
// Returns "" when the hostname is not of the form mpd-<NNN>, which the
// caller reports rather than guessing at.
func DeriveVMID() string {
	// /etc/hostname directly rather than the hostname(1) binary: the
	// file is always present on Debian and needs no allow-list entry.
	body, err := os.ReadFile("/etc/hostname")
	if err != nil {
		return ""
	}
	return VMIDFromHostname(string(body))
}

// VMIDFromHostname extracts the identifier from a hostname string.
func VMIDFromHostname(raw string) string {
	host := strings.TrimSpace(raw)
	// Strip any FQDN form: only the short name carries the identifier.
	host, _, _ = strings.Cut(host, ".")
	id, found := strings.CutPrefix(host, "mpd-")
	if !found {
		return ""
	}
	return id
}

func parseEnv(text string) map[string]string {
	out := map[string]string{}
	for _, raw := range strings.Split(text, "\n") {
		line := strings.TrimSpace(raw)
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		key, value, found := strings.Cut(line, "=")
		if !found {
			continue
		}
		if len(value) >= 2 && strings.HasPrefix(value, `"`) && strings.HasSuffix(value, `"`) {
			value = value[1 : len(value)-1]
		}
		out[key] = value
	}
	return out
}
