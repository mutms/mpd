// mpd — Namespace root.
// Open this file to see the full API surface. Each nested enum is implemented
// in the matching .swift file under the corresponding directory.
//
// Top-level Mpd statics: dataVolume name, internalSubnet, ServiceDescriptor.
//
//   Mpd.Net.*                      addressing: subnet, IPs, DNS zone         → Net.swift
//
//   Mpd.Action.{Setup,Start,Stop,Restart,Status}   verb entry points          → Action/*.swift
//
//   Mpd.VM.*                       VM host operations + path constants        → VM/VM.swift
//     Mpd.VM.exec/capture          host command gateway                       → VM/Exec.swift
//     Mpd.VM.detect{User,UID},     dev identity + ssh keys                    → VM/Identity.swift
//       authorizedPublicKeys, label, fileFingerprint
//     Mpd.VM.installShutdownUnit() systemd user-unit installer                → VM/ShutdownUnit.swift
//     Mpd.VM.warnIfRemoteLoginEnabled()                                       → VM/DNS.swift
//     Mpd.VM.DNS.*                 DNS resolver state, recipe install         → VM/DNS.swift
//     Mpd.VM.Certificate.*         CA + cert generation                       → VM/Certificate.swift
//     Mpd.VM.assetsPath()          asset path resolution (throwing)           → VM/VM.swift
//     Mpd.VM.DataVolume.*          /srv volume rescan helpers                 → VM/DataVolume.swift
//     Mpd.VM.Platform.*            platform.env reader/writer                 → VM/Platform.swift
//     Mpd.VM.Config.*              user/uid persistence + VMConfig struct     → VM/Config.swift
//
//   Mpd.Runtime.*                  runtime lifecycle, isValidName(_:)         → Runtime/Runtime.swift
//   Mpd.Project.*                  project actions, isValidName(_:)           → Runtime/Project.swift
//   Mpd.Runtime.DB.*               DB containers                              → Runtime/DB.swift
//   Mpd.Runtime.State.*            runtime/project registry                   → Runtime/RuntimeState.swift
//
//   Mpd.Service.{Dnsmasq,Portal,Adminer,FileAccess}    infra service lifecycle  → Service/Service*.swift
//
//   Mpd.Podman.*                   Podman CLI gateway                         → Util/Podman.swift
//   Mpd.Completion.emit/install    shell completion emitter + shim installer  → CLI/{Complete,InstallCompletion}.swift
//
// JSONStateStore is a plain struct (not under Mpd) — VM/JSONStateStore.swift.

import Foundation

enum Mpd {
    /// Fixed name for the single data volume — all persistent state lives here.
    static let dataVolume = "mpd-data-volume"

    /// Podman network shared by all containers — single /24, plenty of room for
    /// the handful of services + DBs + runtimes mpd actually creates.
    /// Composed by `Mpd.Net`, which owns the whole address layout:
    ///   .1            gateway (Podman bridge)
    ///   .3            dnsmasq
    ///   .4            portal
    ///   .5            fileaccess (volume tool — `podman exec` target)
    ///   .6            adminer (proxied via portal)
    ///   .30–.99       DB containers (allocated by Mpd.Runtime.DB.allocateIP,
    ///                 pinned at create time; vacated slots are reusable)
    ///   .100+         runtimes (php=.100, node=.101, util=.102) — see each
    ///                 runtime's configuration.json
    static var internalSubnet: String { Net.subnet }

    // MARK: - Namespaces

    enum Action {
        enum Setup {}
        enum Start {}
        enum Stop {}
        enum Restart {}
        enum Status {}
    }

    enum VM {
        enum DNS {}
        enum Certificate {}
        enum DataVolume {}
        enum Platform {}
        enum Config {}
    }

    enum Runtime {
        enum DB {}
        enum State {}
    }
    enum Project {}

    enum Podman {}

    /// Addressing — container subnet + `*.mpd.test` zone. See Net.swift.
    enum Net {}

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
            let resolvedDNS = dns ?? Net.service(name)
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
