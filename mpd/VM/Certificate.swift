// mpd — Mpd.VM.Certificate namespace
// OpenSSL-backed CA and leaf cert generation, called by Mpd.Action.Setup.

import Foundation

extension Mpd.VM.Certificate {

    /// CA generation — KEEP IN SYNC with the host-side twin: the Swift
    /// CA generator in mpd-virt-macos (`CA.swift`) and the `generate_mpd_ca`
    /// bash function in `setup/linux/lib/common.sh`. The host-side
    /// orchestrator generates (or reuses) a CA *before* VM creation and
    /// uploads it; mpd inside the VM detects the existing CA via the
    /// `fileExists` check in `Mpd.Action.Setup.execute()` and reuses it.
    /// All three implementations must produce certs with identical DN,
    /// v3_ca extensions, and name constraints.
    static func generateCA(caKeyPath: String, caCertPath: String, certsDir: String) throws {
        let caConf = "\(certsDir)/mpd-ca.conf"
        let caConfContent = """
            [ req ]
            distinguished_name = req_dn
            x509_extensions    = v3_ca
            prompt             = no

            [ req_dn ]
            O  = mpd.test local development CA
            CN = mpd.test local development CA

            [ v3_ca ]
            basicConstraints       = critical, CA:TRUE, pathlen:0
            subjectKeyIdentifier   = hash
            keyUsage               = critical, keyCertSign, cRLSign
            nameConstraints        = critical, @name_constraints

            [ name_constraints ]
            permitted;DNS.0        = .mpd.test
            permitted;DNS.1        = mpd.test
            """
        try caConfContent.write(toFile: caConf, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(atPath: caConf) }

        guard Mpd.VM.exec(["openssl", "genrsa", "-out", caKeyPath, "4096"]) == 0,
              Mpd.VM.exec(["openssl", "req", "-new", "-x509",
                     "-key", caKeyPath, "-out", caCertPath,
                     "-days", "3650", "-config", caConf]) == 0
        else { throw RuntimeError("Failed to generate CA certificate.") }
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: caKeyPath)
    }

    static func generateCert(
        sans: [String],
        certPath: String,
        keyPath: String,
        caKeyPath: String,
        caCertPath: String,
        certsDir: String
    ) throws {
        let csr = "\(certsDir)/tmp.csr"
        let extFile = "\(certsDir)/tmp.ext"
        let cn = sans.first ?? "mpd.test"
        let sanList = sans.map { "DNS:\($0)" }.joined(separator: ", ")

        let extContent = """
            authorityKeyIdentifier=keyid,issuer
            basicConstraints=CA:FALSE
            keyUsage = digitalSignature, nonRepudiation, keyEncipherment, dataEncipherment
            subjectAltName = \(sanList)
            """
        try extContent.write(toFile: extFile, atomically: true, encoding: .utf8)
        defer {
            try? FileManager.default.removeItem(atPath: csr)
            try? FileManager.default.removeItem(atPath: extFile)
        }

        guard Mpd.VM.exec(["openssl", "genrsa", "-out", keyPath, "2048"]) == 0,
              Mpd.VM.exec(["openssl", "req", "-new", "-key", keyPath, "-out", csr,
                     "-subj", "/CN=\(cn)"]) == 0,
              Mpd.VM.exec(["openssl", "x509", "-req",
                     "-in", csr, "-CA", caCertPath, "-CAkey", caKeyPath,
                     "-CAcreateserial", "-out", certPath,
                     "-days", "397", "-extfile", extFile]) == 0
        else { throw RuntimeError("Failed to generate certificate for \(cn).") }
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: keyPath)
    }

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
            if Mpd.VM.exec(["update-ca-certificates"]) == 0 {
                ok("CA installed in system trust store.")
            } else {
                print("  Warning: update-ca-certificates failed.")
            }
            return
        }

        print("Installing the mpd CA into the system trust store (sudo).")
        guard Mpd.VM.exec(["sudo", "install", "-D", "-m", "644", caPath, dest]) == 0 else {
            print("  Warning: failed to install \(dest).")
            return
        }
        guard Mpd.VM.exec(["sudo", "update-ca-certificates"]) == 0 else {
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
            if Mpd.VM.exec(mkdirArgs) != 0 {
                print("  Warning: failed to create \(policyDir).")
                return
            }
        }

        if needsCertCopy {
            let copyArgs = sudoPrefix + ["install", "-m", "644", caPath, certPathInPolicy]
            if Mpd.VM.exec(copyArgs) != 0 {
                print("  Warning: failed to install \(certPathInPolicy).")
                return
            }
        }

        let installArgs = sudoPrefix + ["install", "-D", "-m", "644", tmpPath, policyPath]
        if Mpd.VM.exec(installArgs) == 0 {
            ok("\(label) enterprise policy installed at \(policyPath).")
        } else {
            print("  Warning: failed to install \(policyPath).")
        }
    }
}
