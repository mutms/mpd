// mpd — Mpd.Net namespace: the single source of truth for mpd's addressing.
//
// Every container IP and every `*.mpd.test` name mpd composes goes through
// here. Nothing outside this file should contain `10.163.` or `mpd.test` as
// a literal — if you find yourself typing one, add an accessor instead.
//
// Mirrors `mpd-virt/Net.swift` in the host-side mpd-virt repo, which holds
// the same two facts for the workstation end (route target + resolver
// target). The two must agree; they are separate repos, so a change here is
// a change there.
//
// ── Why this exists ────────────────────────────────────────────────────
// mpd VMs used to build an identical address space: `10.163.0.0/24` with
// dnsmasq on `.3`, and a flat `<name>.mpd.test` zone. That is fine for one
// VM and breaks for two — the workstation can only route `10.163.0.0/24` to
// one next hop, and `moodle45.mpd.test` named a project on either VM with
// nothing to tell them apart.
//
// The VM's own ID (`MPD_VM_ID` — a 3-digit value in [100, 254] for managed
// VMs, `000` for sandbox) is therefore the discriminator in both halves:
// subnet `10.163.<id>.0/24`, zone `<id>.mpd.test`. It is a valid octet by
// construction, so it is used directly. Full model — including why both
// halves are required and why the bare apex no longer resolves — in
// docs/NETWORKING.md.
//
// ── Addressing ─────────────────────────────────────────────────────────
// VM 222 gets subnet `10.163.222.0/24` and zone `222.mpd.test`; VM 150 gets
// `10.163.150.0/24` and `150.mpd.test`. The sandbox VM is `000` — not a
// special case, just the zeroth VM, and it keeps the `10.163.0.0/24` that
// every VM used before this change.
//
// The host part of an address never moves: dnsmasq is always `.3`, the
// portal always `.4`, runtimes always `.100+`. Only the third octet varies,
// and it always equals the VM ID.

import Foundation

extension Mpd.Net {

    // MARK: - Fixed facts

    /// The DNS root mpd owns. Constant across every VM — it is what the CA's
    /// name constraint permits (`permitted;DNS.0 = .mpd.test`), so one CA
    /// covers every VM regardless of per-VM zoning. Use this only for
    /// CA-level and resolver-level concerns that are deliberately
    /// VM-independent; for anything naming a *host on this VM*, use `zone`.
    static let rootDomain = "mpd.test"

    /// First two octets of the container address space. `10.163.0.0/16` is
    /// reserved by mpd in aggregate: each VM takes one /24 inside it.
    static let subnetPrefix = "10.163"

    /// Host octets with a fixed meaning inside every VM's /24.
    enum Host {
        static let gateway = 1      // Podman bridge — the VM itself
        static let dnsmasq = 3
        static let portal = 4
        static let fileaccess = 5
        static let adminer = 6
    }

    /// DB containers get the lowest free octet in this range, pinned at
    /// create time. Vacated slots are reusable. See `Mpd.Runtime.DB.allocateIP`.
    static let dbHostRange = 30...99

    /// Runtimes start here (php=.100, node=.101, util=.102) — each runtime's
    /// `configuration.json` names its own octet.
    static let firstRuntimeHost = 100

    // MARK: - Per-VM facts

    /// Third octet of this VM's container subnet. Equals the VM's ID.
    static var octet: Int { identity.octet }

    /// This VM's DNS zone — the suffix every mpd-managed name ends with, and
    /// the apex that resolves to the portal. e.g. `222.mpd.test`.
    static var zone: String { "\(identity.label).\(rootDomain)" }

    /// The VM's 3-digit ID as written in the zone and derived from
    /// `MPD_VM_ID`, normalised to three digits (`22` → `022`).
    static var vmId: String { identity.label }

    /// Resolved once per process from `/var/lib/mpd/conf/platform.env`.
    ///
    /// A missing or malformed `MPD_VM_ID` is fatal, deliberately: every
    /// address and every name mpd composes depends on it, so the failure
    /// modes of guessing are "silently build the wrong subnet" and "answer
    /// for another VM's zone". Refusing to run is the legible outcome (see
    /// AGENTS.md — prefer deterministic behavior over convenience
    /// fallbacks).
    ///
    /// Resolved lazily rather than as a `main.swift` preflight on purpose:
    /// `mpd --setup` re-derives MPD_VM_ID from the VM hostname and rewrites
    /// platform.env early in its run, so a VM with a hand-broken value can
    /// still repair itself. A preflight would refuse before reaching that
    /// step.
    static var identity: (label: String, octet: Int) {
        if let cached = cachedIdentity { return cached }
        do {
            let resolved = try resolveIdentity()
            cachedIdentity = resolved
            return resolved
        } catch {
            errPrint(error.localizedDescription)
            exit(1)
        }
    }

    /// Non-fatal form, for `main.swift`'s preflight and for tests: returns
    /// the identity or throws a message naming the fix.
    static func resolveIdentity() throws -> (label: String, octet: Int) {
        let raw = (try Mpd.VM.Platform.load()).vmId
        guard !raw.isEmpty else {
            throw RuntimeError(identityErrorText("MPD_VM_ID is empty"))
        }
        guard let value = Int(raw), (0...254).contains(value) else {
            throw RuntimeError(identityErrorText("MPD_VM_ID='\(raw)' is not an octet in [0, 254]"))
        }
        return (label: String(format: "%03d", value), octet: value)
    }

    private static func identityErrorText(_ problem: String) -> String {
        """
        Cannot determine this VM's identity — \(problem).

        mpd derives its container subnet (10.163.<id>.0/24) and its DNS zone
        (<id>.mpd.test) from MPD_VM_ID in \(Mpd.VM.Platform.path).
        Re-run the bootstrap step that writes it:
            bash /opt/mpd/bootstrap/30-networking.sh <NNN>   # sandbox: 000; managed: 100..254
        """
    }

    nonisolated(unsafe) private static var cachedIdentity: (label: String, octet: Int)?

    // MARK: - Derived addressing

    /// This VM's container subnet in CIDR form, e.g. `10.163.222.0/24`.
    /// Passed to `podman network create`.
    static var subnet: String { "\(subnetPrefix).\(octet).0/24" }

    /// The Podman bridge address — the VM itself as seen from containers.
    static var gateway: String { ip(Host.gateway) }

    /// Compose a container address from its host octet, e.g. on VM 222
    /// `ip(Host.dnsmasq)` → `10.163.222.3`.
    static func ip(_ host: Int) -> String {
        precondition((0...255).contains(host), "host octet out of range: \(host)")
        return "\(subnetPrefix).\(octet).\(host)"
    }

    /// True when `address` sits inside this VM's /24. Used when scanning
    /// live containers for allocated slots — a container on some other
    /// network must not consume one.
    static func contains(_ address: String) -> Bool {
        hostOctet(of: address) != nil
    }

    /// The host octet of `address` if it is inside this VM's /24, else nil.
    static func hostOctet(of address: String) -> Int? {
        let parts = address.split(separator: ".")
        guard parts.count == 4,
              parts[0] == "10", parts[1] == "163",
              Int(parts[2]) == octet,
              let host = Int(parts[3]) else { return nil }
        return host
    }

    // MARK: - Derived naming

    /// Qualify a name into this VM's zone — on VM 222:
    ///   `host("php.runtime")`  → `php.runtime.222.mpd.test`
    ///   `host("moodle45")`     → `moodle45.222.mpd.test`
    ///
    /// Pass the *unqualified* left-hand part only — never a name that
    /// already ends in the zone.
    static func host(_ name: String) -> String {
        precondition(!name.hasSuffix(rootDomain),
                     "host(_:) takes an unqualified name, got: \(name)")
        return "\(name).\(zone)"
    }

    /// A service's canonical name: `service("portal")` → `portal.service.<zone>`.
    static func service(_ name: String) -> String { host("\(name).service") }

    /// A runtime's canonical name: `runtime("php")` → `php.runtime.<zone>`.
    static func runtime(_ name: String) -> String { host("\(name).runtime") }

    /// A database's canonical name: `db("pg17")` → `pg17.db.<zone>`.
    static func db(_ name: String) -> String { host("\(name).db") }

    /// True when `name` is this VM's zone apex or a name beneath it — i.e.
    /// something mpd is entitled to issue a cert and a DNS record for. A
    /// stray URL naming *another* VM's zone does not match, so it is never
    /// silently given a local cert and DNS record here.
    static func isInZone(_ name: String) -> Bool {
        name == zone || name.hasSuffix(".\(zone)")
    }
}
