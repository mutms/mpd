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
// Today every mpd VM builds the *same* address space: `10.163.0.0/24` with
// dnsmasq on `.3`, and a flat `<name>.mpd.test` zone. That is fine for one
// VM and breaks for two — the workstation can only route `10.163.0.0/24` to
// one next hop, and `moodle45.mpd.test` names a project on either VM with
// nothing to tell them apart.
//
// The fix is to make the VM's own ID (`MPD_VM_ID`, already a 3-digit value
// in [100, 254] for managed VMs and `000` for sandbox) the discriminator in
// both halves: subnet `10.163.<id>.0/24`, zone `<id>.mpd.test`. See
// docs/proposals/per-vm-addressing.md.
//
// ── Current phase ──────────────────────────────────────────────────────
// **Phase 1 (this commit): values are unchanged.** `octet` is hardcoded to
// 0 and `zone` to the bare root domain, so this module emits exactly what
// the scattered literals used to. That makes the conversion of ~165 call
// sites a verifiable no-op.
//
// **Phase 2 flips two properties** — `octet` and `zone` — and nothing else.
// Both carry a PHASE 2 comment with the replacement body.

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

    /// Third octet of this VM's container subnet, and the label of its DNS
    /// zone. Equals the VM's ID by construction.
    ///
    /// PHASE 2: `try Int(vmId) ?? { throw … }` — see `vmId` below.
    static var octet: Int { 0 }

    /// This VM's DNS zone — the suffix every mpd-managed name ends with, and
    /// the apex that resolves to the portal.
    ///
    /// PHASE 2: `"\(vmIdString).\(rootDomain)"` → e.g. `222.mpd.test`.
    static var zone: String { rootDomain }

    /// The VM's 3-digit ID from `/var/lib/mpd/conf/platform.env`, cached for
    /// the process. Nil when the identity file is absent or has no
    /// `MPD_VM_ID` — i.e. before bootstrap has run.
    ///
    /// Unused in phase 1. In phase 2 `octet` and `zone` derive from it, and
    /// a nil here must be a hard error rather than a fallback to some
    /// default VM: silently addressing the wrong subnet is worse than
    /// refusing to start (see AGENTS.md, "prefer deterministic behavior over
    /// convenience fallbacks").
    static var vmId: String? {
        if let cached = cachedVmId { return cached.value }
        let value = (try? Mpd.VM.Platform.load())?.vmId
        cachedVmId = (value?.isEmpty == false) ? Box(value) : Box(nil)
        return cachedVmId?.value
    }

    private final class Box { let value: String?; init(_ v: String?) { value = v } }
    nonisolated(unsafe) private static var cachedVmId: Box?

    // MARK: - Derived addressing

    /// This VM's container subnet in CIDR form, e.g. `10.163.0.0/24`.
    /// Passed to `podman network create`.
    static var subnet: String { "\(subnetPrefix).\(octet).0/24" }

    /// The Podman bridge address — the VM itself as seen from containers.
    static var gateway: String { ip(Host.gateway) }

    /// Compose a container address from its host octet: `ip(3)` → `10.163.0.3`.
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

    /// Qualify a name into this VM's zone:
    ///   `host("php.runtime")`  → `php.runtime.mpd.test`
    ///   `host("moodle45")`     → `moodle45.mpd.test`
    /// (phase 2: `php.runtime.222.mpd.test`, `moodle45.222.mpd.test`)
    ///
    /// Pass the *unqualified* left-hand part only — never a name that
    /// already ends in the zone.
    static func host(_ name: String) -> String {
        precondition(!name.hasSuffix(rootDomain),
                     "host(_:) takes an unqualified name, got: \(name)")
        return "\(name).\(zone)"
    }

    /// A service's canonical name: `service("portal")` → `portal.service.mpd.test`.
    static func service(_ name: String) -> String { host("\(name).service") }

    /// A runtime's canonical name: `runtime("php")` → `php.runtime.mpd.test`.
    static func runtime(_ name: String) -> String { host("\(name).runtime") }

    /// A database's canonical name: `db("pg17")` → `pg17.db.mpd.test`.
    static func db(_ name: String) -> String { host("\(name).db") }

    /// True when `name` is this VM's zone apex or a name beneath it — i.e.
    /// something mpd is entitled to issue a cert and a DNS record for.
    ///
    /// Phase 2 makes this meaningfully narrower: a stray URL naming *another*
    /// VM's zone stops matching, rather than being silently given a local
    /// cert and DNS record here.
    static func isInZone(_ name: String) -> Bool {
        name == zone || name.hasSuffix(".\(zone)")
    }
}
