// mpd — Formatted text output
// Context-aware status (--status) and the renderers used by `mpd list`
// (projects / runtimes / services / dbs).

import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

private func supportsAnsiColor() -> Bool {
    guard isatty(STDOUT_FILENO) == 1 else { return false }
    let term = ProcessInfo.processInfo.environment["TERM"] ?? ""
    return !term.isEmpty && term != "dumb"
}

private func colorStatus(_ status: String) -> String {
    guard supportsAnsiColor() else { return status }
    switch status {
    case "running":
        return "\u{001B}[32m\(status)\u{001B}[0m"
    case "stopped":
        return "\u{001B}[33m\(status)\u{001B}[0m"
    case "not-created":
        return "\u{001B}[31m\(status)\u{001B}[0m"
    default:
        return status
    }
}

private func colorStatusLabel(_ status: String, width: Int) -> String {
    let padded = status.count < width ? status.padding(toLength: width, withPad: " ", startingAt: 0) : status + "  "
    guard supportsAnsiColor() else { return padded }
    switch status {
    case "running":
        return "\u{001B}[32m\(padded)\u{001B}[0m"
    case "stopped":
        return "\u{001B}[33m\(padded)\u{001B}[0m"
    case "not-created":
        return "\u{001B}[31m\(padded)\u{001B}[0m"
    default:
        return padded
    }
}

// MARK: - Status display (--status)

extension Mpd {

    static func showList() {
        let projects = Mpd.Runtime.State.loadProjects().projects
        guard !projects.isEmpty else { print("No projects found."); return }

        // Cross-check against live Podman state so a stopped runtime
        // doesn't leave its projects showing as "running".
        let runningRuntimes = Set(
            Mpd.Podman.ps(filter: "label=mpd.runtime")
                .filter { $0.State == "running" }
                .compactMap { $0.Labels?["mpd.name"] }
        )

        func col(_ s: String, _ w: Int) -> String {
            s.count < w ? s.padding(toLength: w, withPad: " ", startingAt: 0) : s + "  "
        }
        print(col("PROJECT", 14) + col("STATUS", 10) + col("TYPE", 12) +
              col("RUNTIME", 10) + col("DB", 14) + "URL")
        print(String(repeating: "─", count: 94))

        for p in projects.sorted(by: { $0.name < $1.name }) {
            let url = Mpd.Project.projectURL(entry: p)
            let dbStr = p.databaseId.isEmpty ? "-" : p.databaseId
            let rtStr = p.runtimeName.isEmpty ? "—" : p.runtimeName
            let effectiveStatus = (p.status == .running && !p.runtimeName.isEmpty
                && !runningRuntimes.contains(p.runtimeName))
                ? ProjectLifecycleStatus.stopped.rawValue
                : p.status.rawValue
            print(col(p.name, 14) + colorStatusLabel(effectiveStatus, width: 10) + col(p.type, 12) +
                  col(rtStr, 10) + col(dbStr, 14) + url)
        }
    }

    static func showServiceList() {
        func col(_ s: String, _ w: Int) -> String {
            s.count < w ? s.padding(toLength: w, withPad: " ", startingAt: 0) : s + "  "
        }

        // Take one snapshot to avoid per-service inspect races.
        let snapshot = Mpd.Podman.ps(filter: "label=com.docker.compose.project=mpd-service")
        var stateByContainer: [String: String] = [:]
        for item in snapshot {
            if let name = item.Names.first {
                stateByContainer[name] = item.State
            }
        }

        print(col("SERVICE", 14) + col("STATUS", 12) + col("IP", 16) + "ACCESS")
        print(String(repeating: "─", count: 92))

        func ipSortKey(_ ip: String) -> [Int] {
            ip.split(separator: ".").compactMap { Int($0) }
        }

        let orderedServices = Mpd.services.sorted {
            let leftKey = ipSortKey($0.ip)
            let rightKey = ipSortKey($1.ip)
            if leftKey != rightKey { return leftKey.lexicographicallyPrecedes(rightKey) }
            return $0.name < $1.name
        }

        for service in orderedServices {
            let status: String
            if let state = stateByContainer[service.containerName] {
                status = state == "running" ? "running" : "stopped"
            } else {
                status = "not-created"
            }
            print(col(service.name, 14) + colorStatusLabel(status, width: 12) + col(service.ip, 16) + service.accessHint)
        }
    }

    static func showDbList() {
        let items = Mpd.Podman.ps(filter: "label=mpd.type=db")
        guard !items.isEmpty else { print("No DB containers found."); return }

        let projects = Mpd.Runtime.State.loadProjects().projects
        var projectMap: [String: [String]] = [:]
        for p in projects where !p.databaseId.isEmpty {
            projectMap[p.databaseId, default: []].append(p.name)
        }

        func col(_ s: String, _ w: Int) -> String {
            s.count < w ? s.padding(toLength: w, withPad: " ", startingAt: 0) : s + "  "
        }
        print(col("DATABASE", 16) + col("STATUS", 10) + col("DNS", 28) + "PROJECTS")
        print(String(repeating: "─", count: 84))

        let rows = items.map { item -> (database: String, status: String, dns: String, projects: String) in
            let engine = item.Labels?["mpd.db.engine"] ?? "-"
            let version = item.Labels?["mpd.db.version"] ?? "-"
            let databaseId = item.Labels?["mpd.name"] ?? "\(engine)-\(version.replacingOccurrences(of: ".", with: "-"))"
            let database = "\(engine):\(version)"
            let status = item.State == "running" ? "running" : "stopped"
            let dns = "\(databaseId).db.mpd.test"
            let projectsList = projectMap[databaseId]?.sorted().joined(separator: ", ") ?? "-"
            return (database: database, status: status, dns: dns, projects: projectsList)
        }.sorted { $0.database < $1.database }

        for row in rows {
            print(col(row.database, 16) + colorStatusLabel(row.status, width: 10) + col(row.dns, 28) + row.projects)
        }
    }
}

