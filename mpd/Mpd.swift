// mpd — Namespace root
// Open this file to see the full API surface.
// Each nested enum is implemented in the matching .swift file via extension.
//
//   Mpd.Action.{Setup,Start,Stop,Restart,Status}  lifecycle verbs        → Environment/Action*.swift
//   Mpd.Certificate.*       CA + cert generation  → Environment/Certificate.swift
//   Mpd.HostExec.*          Process() gateway     → Environment/HostExec.swift
//   Mpd.Integration.*       DNS / resolver checks → Environment/Integration.swift
//   Mpd.ShutdownUnit.*      systemd unit installer→ Environment/ShutdownUnit.swift
//   Mpd.Runtime.*           runtime lifecycle     → Runtime/Runtime.swift
//   Mpd.Project.*           project actions       → Runtime/Project.swift
//   Mpd.Runtime.DB.*        DB containers         → Runtime/DB.swift
//   Mpd.Runtime.State.*     runtime/project state → Runtime/RuntimeState.swift
//   Mpd.Core.Assets.*       path resolution       → Core/Assets.swift
//   Mpd.Core.DataVolume.*   volume operations     → Core/DataVolume.swift
//   Mpd.Core.State.*        global/machine state  → Core/CoreState.swift
//   Mpd.Core.Platform.*     platform.env reader   → Core/Platform.swift
//   Mpd.Podman.*            Podman CLI layer      → Util/Podman.swift
//
//   Top-level helpers on Mpd directly (Environment.swift + Machine.swift):
//     paths               homeDir, mpdDir, dotMpdDir, confDir, confCARootDir,
//                         confServiceDir, confTempDir, assetsDir, binDir
//     identity            label, fileFingerprint, detectUserAndUID,
//                         authorizedPublicKeys
//
//   Services (each owns its container lifecycle):
//   Mpd.Service.Dnsmasq.*    DNS resolver         → Service/ServiceDnsmasq.swift
//   Mpd.Service.Portal.*     status dashboard     → Service/ServicePortal.swift
//   Mpd.Service.Adminer.*    DB management UI     → Service/ServiceAdminer.swift
//   Mpd.Service.FileAccess.* Data-volume exec target → Service/ServiceFileAccess.swift
//
// Mailpit, selenium, and valkey were global services before Phase 9; they now
// run as per-runtime sidecars (Mpd.Runtime.{mailpit,selenium,valkey}SidecarSpec).
// Mailpit attaches when a runtime declares `defaultSidecars: ["mailpit"]` in
// its configuration.json (PHP runtime does); selenium attaches on demand when
// any project on the runtime has a `kind: behat` URL; valkey is wired but
// nothing currently triggers it — first project type to need it adds the
// trigger source.

import Foundation

enum Mpd {
    /// Fixed name for the single data volume — all persistent state lives here.
    static let dataVolume = "mpd-data-volume"

    /// Podman network shared by all containers — single /24, plenty of room for
    /// the handful of services + DBs + runtimes mpd actually creates.
    /// Address layout (all 10.163.0.x):
    ///   .1            gateway (Podman bridge)
    ///   .3            dnsmasq
    ///   .4            portal
    ///   .5            fileaccess (volume tool — `podman exec` target)
    ///   .6            adminer (proxied via portal)
    ///   .30–.99       DB containers (allocated by Mpd.Runtime.DB.allocateIP,
    ///                 pinned at create time; vacated slots are reusable)
    ///   .100+         runtimes (php=.100, node=.101, util=.102) — see each
    ///                 runtime's configuration.json
    /// Post-Phase 9, only true infra services remain in the global registry:
    /// `dnsmasq`, `portal`, `adminer`, `fileaccess`.
    /// Mailpit/selenium/valkey are per-runtime sidecars now.
    static let internalSubnet = "10.163.0.0/24"

    // MARK: - Namespaces

    enum Action {
        enum Setup {}
        enum Start {}
        enum Stop {}
        enum Restart {}
        enum Status {}
    }
    enum Integration {}
    enum Certificate {}
    enum HostExec {}
    enum ShutdownUnit {}
    enum Runtime {
        enum DB {}
        enum State {}
    }
    enum Project {}
    enum Core {
        enum Assets {}
        enum DataVolume {}
        enum PersonalArea {}
        enum Platform {}
        enum State {}
    }
    enum Podman {}

    /// Shell-completion candidate emitter — see `Mpd.Completion.emit(cword:words:)`.
    enum Completion {}

    // Services — each file owns its container's full lifecycle.
    enum Service {
        enum Dnsmasq {}
        enum Portal {}
        enum Adminer {}
        enum FileAccess {}
    }

    // MARK: - Service registry

    struct ServicePortalProxy {
        let upstreamScheme: String
        let upstreamPort: Int

        init(upstreamScheme: String = "http", upstreamPort: Int) {
            self.upstreamScheme = upstreamScheme
            self.upstreamPort = upstreamPort
        }
    }

    /// Single source of truth for mpd services and their discoverability metadata.
    struct ServiceDescriptor {
        let name: String
        let containerName: String
        let ip: String
        let dns: String
        let accessHint: String
        let dnsAliases: [String]
        let dnsTargetIP: String?
        let portalProxy: ServicePortalProxy?
        let setup: (() throws -> Void)?
        let start: (() throws -> Void)?
        let stop: (() throws -> Void)?

        init(
            name: String,
            containerName: String,
            ip: String,
            dns: String,
            accessHint: String,
            dnsAliases: [String],
            dnsTargetIP: String? = nil,
            portalProxy: ServicePortalProxy? = nil,
            setup: (() throws -> Void)?,
            start: (() throws -> Void)?,
            stop: (() throws -> Void)?
        ) {
            precondition(ServiceDescriptor.isValidServiceName(name), "Invalid service name: \(name)")
            precondition(containerName.hasPrefix("mpd-service-"), "Container name must start with mpd-service-")
            precondition(!dns.isEmpty, "DNS must not be empty")
            precondition(dnsAliases.contains(dns), "dnsAliases must include primary dns")
            precondition(!(portalProxy != nil && dnsTargetIP != nil), "portalProxy and dnsTargetIP are mutually exclusive")

            self.name = name
            self.containerName = containerName
            self.ip = ip
            self.dns = dns
            self.accessHint = accessHint
            self.dnsAliases = dnsAliases
            self.dnsTargetIP = dnsTargetIP
            self.portalProxy = portalProxy
            self.setup = setup
            self.start = start
            self.stop = stop
        }

        init(
            name: String,
            ip: String,
            accessHint: String,
            containerName: String? = nil,
            dns: String? = nil,
            dnsAliases: [String]? = nil,
            dnsTargetIP: String? = nil,
            portalProxy: ServicePortalProxy? = nil,
            setup: (() throws -> Void)?,
            start: (() throws -> Void)?,
            stop: (() throws -> Void)?
        ) {
            let resolvedContainer = containerName ?? "mpd-service-\(name)"
            let resolvedDNS = dns ?? "\(name).service.mpd.test"
            let resolvedAliases = dnsAliases ?? [resolvedDNS]
            self.init(
                name: name,
                containerName: resolvedContainer,
                ip: ip,
                dns: resolvedDNS,
                accessHint: accessHint,
                dnsAliases: resolvedAliases,
                dnsTargetIP: dnsTargetIP,
                portalProxy: portalProxy,
                setup: setup,
                start: start,
                stop: stop
            )
        }

        private static func isValidServiceName(_ name: String) -> Bool {
            let regex = try? NSRegularExpression(pattern: "^[a-z0-9-]+$")
            let range = NSRange(location: 0, length: name.utf16.count)
            return regex?.firstMatch(in: name, options: [], range: range) != nil
        }
    }

    static let services: [ServiceDescriptor] = [
        Service.Dnsmasq.descriptor,
        Service.Portal.descriptor,
        Service.Adminer.descriptor,
        Service.FileAccess.descriptor,
    ]

    static func service(named name: String) -> ServiceDescriptor? {
        services.first { $0.name == name }
    }

    static var serviceDNSRecords: [(host: String, ip: String)] {
        services.flatMap { service in
            let targetIP: String
            if service.portalProxy != nil {
                targetIP = Service.Portal.ip
            } else {
                targetIP = service.dnsTargetIP ?? service.ip
            }
            return service.dnsAliases.map { ($0, targetIP) }
        }
    }

    // MARK: - Service access hints

    static func serviceDNS(_ name: String) -> String {
        service(named: name)?.dns ?? "—"
    }

    static func serviceAccessHint(_ name: String) -> String {
        service(named: name)?.accessHint ?? "—"
    }
}
