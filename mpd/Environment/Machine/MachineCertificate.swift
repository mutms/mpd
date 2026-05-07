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

    /// Install a Firefox-ESR enterprise policy that imports the mpd CA into
    /// every Firefox profile on the VM. Firefox uses NSS, not the OS trust
    /// store; on Linux `Certificates.ImportEnterpriseRoots` is a no-op
    /// (Mozilla's Linux build has no p11-kit code path), so we use the
    /// `Certificates.Install` policy which loads PEM files directly into NSS.
    /// The referenced CA file is the same one `trustCA` already manages.
    /// Idempotent. Harmless when firefox-esr is not installed.
    ///
    /// Path note: Firefox resolves the policy file via `XREAppDist`, which
    /// on Linux is `<install-dir>/distribution/`. For Debian's firefox-esr
    /// package that's `/usr/lib/firefox-esr/distribution/policies.json`.
    /// The Debian-side `/etc/firefox-esr/policies/` directory looks
    /// official but is *not* read by Firefox itself — wrong path, no
    /// effect.
    static func installFirefoxPolicy() {
        let policyPath = "/usr/lib/firefox-esr/distribution/policies.json"
        let caInPolicy = "/usr/local/share/ca-certificates/mpd-local.crt"
        let policyJSON = #"{"policies":{"Certificates":{"Install":["\#(caInPolicy)"]}}}"# + "\n"

        let fm = FileManager.default
        if let existing = fm.contents(atPath: policyPath),
           String(data: existing, encoding: .utf8) == policyJSON {
            ok("Firefox-ESR enterprise policy already in place.")
            return
        }

        // Stage in $TMPDIR (user-writable), then drop into /etc via install(1).
        let tmpPath = NSTemporaryDirectory() + "mpd-firefox-policies.json"
        do {
            try policyJSON.write(toFile: tmpPath, atomically: true, encoding: .utf8)
        } catch {
            print("  Warning: failed to stage Firefox policy: \(error.localizedDescription)")
            return
        }
        defer { try? fm.removeItem(atPath: tmpPath) }

        let installArgs = ["install", "-D", "-m", "644", tmpPath, policyPath]
        let exitCode: Int32
        if geteuid() == 0 {
            exitCode = Mpd.Environment.HostExec.run(installArgs)
        } else {
            exitCode = Mpd.Environment.HostExec.run(["sudo"] + installArgs)
        }
        if exitCode == 0 {
            ok("Firefox-ESR enterprise policy installed at \(policyPath).")
        } else {
            print("  Warning: failed to install \(policyPath).")
        }
    }
}
#endif
