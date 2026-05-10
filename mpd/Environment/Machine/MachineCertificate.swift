// mpd-machine certificate trust integration

#if !os(macOS)
import Foundation

extension Mpd.Environment.Certificate {
    static func trustCA(caPath: String) {
        let dest = "/usr/local/share/ca-certificates/mpd-local.crt"
        let fm = FileManager.default
        if fm.fileExists(atPath: dest),
           fm.contents(atPath: caPath) == fm.contents(atPath: dest) {
            ok("CA already installed in system trust store.")
            return
        }
        if geteuid() == 0 {
            try? fm.createDirectory(atPath: "/usr/local/share/ca-certificates",
                                    withIntermediateDirectories: true)
            if fm.fileExists(atPath: dest) { try? fm.removeItem(atPath: dest) }
            try? fm.copyItem(atPath: caPath, toPath: dest)
            if Mpd.Environment.HostExec.run(["update-ca-certificates"]) == 0 {
                ok("CA installed in system trust store.")
            } else {
                print("  Warning: update-ca-certificates failed.")
            }
            return
        }

        print("Installing the mpd CA into the system trust store (sudo).")
        guard Mpd.Environment.HostExec.run(["sudo", "install", "-D", "-m", "644", caPath, dest]) == 0 else {
            print("  Warning: failed to install \(dest).")
            return
        }
        guard Mpd.Environment.HostExec.run(["sudo", "update-ca-certificates"]) == 0 else {
            print("  Warning: update-ca-certificates failed.")
            return
        }
        ok("CA installed in system trust store.")
    }

    /// Install a Firefox enterprise policy that imports the mpd CA into
    /// every Firefox profile on the VM. Firefox uses NSS, not the OS trust
    /// store; on Linux `Certificates.ImportEnterpriseRoots` is a no-op
    /// (Mozilla's Linux build has no p11-kit code path), so we use the
    /// `Certificates.Install` policy which loads PEM files directly into NSS.
    /// Idempotent. Harmless when no Firefox is installed.
    ///
    /// Path strategy: detect the installed Firefox flavor at runtime.
    ///   - If `/usr/lib/firefox-esr/distribution/` exists (Debian Trixie's
    ///     firefox-esr package), write the policy file there. Firefox
    ///     resolves policies via `XREAppDist`, which on Linux is
    ///     `<install-dir>/distribution/`. The CA reference points at the
    ///     copy `trustCA` already installed in the system trust store.
    ///   - Otherwise (Ubuntu snap-Firefox, Mozilla deb, etc.), use the
    ///     Mozilla-documented system-wide path
    ///     `/etc/firefox/policies/policies.json`, and copy the CA cert
    ///     into the same directory. Snap-Firefox's confinement bind-mount
    ///     permits `/etc/firefox/policies/` but generally not
    ///     `/usr/local/share/ca-certificates/`, so the cert must travel
    ///     with the policy file.
    static func installFirefoxPolicy(caPath: String) {
        let firefoxEsrDistDir = "/usr/lib/firefox-esr/distribution"
        let fm = FileManager.default
        let useFirefoxEsrPath = fm.fileExists(atPath: firefoxEsrDistDir)

        let policyDir: String
        let policyPath: String
        let certPathInPolicy: String
        let needsCertCopy: Bool
        let label: String
        if useFirefoxEsrPath {
            policyDir = firefoxEsrDistDir
            policyPath = "\(firefoxEsrDistDir)/policies.json"
            certPathInPolicy = "/usr/local/share/ca-certificates/mpd-local.crt"
            needsCertCopy = false
            label = "Firefox-ESR"
        } else {
            policyDir = "/etc/firefox/policies"
            policyPath = "\(policyDir)/policies.json"
            certPathInPolicy = "\(policyDir)/mpd-rootCA.crt"
            needsCertCopy = true
            label = "Firefox (Mozilla / snap)"
        }

        // Build the policy dict and serialize with sortedKeys so the
        // file content is deterministic (byte-comparable across runs).
        // Homepage policy: nudge users to the portal (`https://mpd.test/`)
        // — the single entry point that lists every project — but leave
        // Locked=false so a user who picks a project-specific homepage
        // (e.g. their main moodle) keeps that preference.
        let policyDict: [String: Any] = [
            "policies": [
                "Certificates": ["Install": [certPathInPolicy]],
                "Homepage": [
                    "URL": "https://mpd.test/",
                    "Locked": false,
                    "StartPage": "homepage",
                ],
            ] as [String: Any]
        ]
        let policyData: Data
        do {
            policyData = try JSONSerialization.data(
                withJSONObject: policyDict,
                options: [.prettyPrinted, .sortedKeys])
        } catch {
            print("  Warning: failed to serialize Firefox policy: \(error.localizedDescription)")
            return
        }
        guard let policyJSON = String(data: policyData, encoding: .utf8).map({ $0 + "\n" }) else {
            print("  Warning: failed to encode Firefox policy as UTF-8.")
            return
        }

        // Idempotency: if the policy JSON is already correct AND, when
        // needed, the staged cert matches the source, nothing to do.
        let policyCurrent: Bool = {
            guard let existing = fm.contents(atPath: policyPath) else { return false }
            return String(data: existing, encoding: .utf8) == policyJSON
        }()
        let certCurrent: Bool = {
            if !needsCertCopy { return true }
            guard let staged = fm.contents(atPath: certPathInPolicy),
                  let source = fm.contents(atPath: caPath) else { return false }
            return staged == source
        }()
        if policyCurrent && certCurrent {
            ok("\(label) enterprise policy already in place at \(policyDir).")
            return
        }

        let tmpPath = NSTemporaryDirectory() + "mpd-firefox-policies.json"
        do {
            try policyJSON.write(toFile: tmpPath, atomically: true, encoding: .utf8)
        } catch {
            print("  Warning: failed to stage Firefox policy: \(error.localizedDescription)")
            return
        }
        defer { try? fm.removeItem(atPath: tmpPath) }

        let sudoPrefix: [String] = (geteuid() == 0) ? [] : ["sudo"]

        // Mozilla path branch: dir doesn't exist by default, install -d.
        // firefox-esr branch: the package owns the directory; skip mkdir.
        if needsCertCopy && !fm.fileExists(atPath: policyDir) {
            let mkdirArgs = sudoPrefix + ["install", "-d", "-m", "755", policyDir]
            if Mpd.Environment.HostExec.run(mkdirArgs) != 0 {
                print("  Warning: failed to create \(policyDir).")
                return
            }
        }

        if needsCertCopy {
            let copyArgs = sudoPrefix + ["install", "-m", "644", caPath, certPathInPolicy]
            if Mpd.Environment.HostExec.run(copyArgs) != 0 {
                print("  Warning: failed to install \(certPathInPolicy).")
                return
            }
        }

        let installArgs = sudoPrefix + ["install", "-D", "-m", "644", tmpPath, policyPath]
        if Mpd.Environment.HostExec.run(installArgs) == 0 {
            ok("\(label) enterprise policy installed at \(policyPath).")
        } else {
            print("  Warning: failed to install \(policyPath).")
        }
    }
}
#endif
