// mpd — ProjectType struct, ProjectTypeConfiguration, and JSON loaders
// ProjectType wraps a type name string. All types must exist in assets/runtimes/<rt>/project_types/<name>/.
// Runtime names must exist in assets/runtimes/<name>/.
// Name validation shared by runtimes and projects.

import Foundation

// MARK: - ProjectType

struct ProjectType {
    let name: String

    init(_ name: String) { self.name = name }

    /// Default runtime name for this type from configuration.json.
    var defaultRuntimeName: String {
        guard !name.isEmpty else { return "" }
        if let config = try? loadConfiguration() {
            return config.assetsRuntime
        }
        return ""
    }

    /// All project type names discovered from assets/runtimes/*/project_types/ directories
    /// (those with configuration.json).
    static func allTypes() -> [String] {
        var types = Set<String>()
        for base in assetsBases() {
            let runtimesDir = "\(base)/runtimes"
            guard let runtimes = try? FileManager.default.contentsOfDirectory(atPath: runtimesDir)
            else { continue }
            for rt in runtimes {
                let typesDir = "\(runtimesDir)/\(rt)/project_types"
                guard let entries = try? FileManager.default.contentsOfDirectory(atPath: typesDir)
                else { continue }
                for entry in entries {
                    if FileManager.default.fileExists(atPath: "\(typesDir)/\(entry)/configuration.json") {
                        types.insert(entry)
                    }
                }
            }
        }
        return types.sorted()
    }

    /// All runtime names discovered from assets/runtimes/ directories (those with build.sh).
    static func allRuntimeNames() -> [String] {
        var names = Set<String>()
        for base in assetsBases() {
            let dir = "\(base)/runtimes"
            guard let entries = try? FileManager.default.contentsOfDirectory(atPath: dir)
            else { continue }
            for entry in entries {
                if FileManager.default.fileExists(atPath: "\(dir)/\(entry)/build.sh") {
                    names.insert(entry)
                }
            }
        }
        return names.sorted()
    }

    /// Check if a runtime name has a corresponding assets/runtimes/<name>/build.sh.
    static func isValidRuntimeName(_ name: String) -> Bool {
        allRuntimeNames().contains(name)
    }

    /// Asset search base directory (~/Developer/mpd/assets).
    static func assetsBases() -> [String] {
        guard let p = try? Mpd.Core.Assets.path() else { return [] }
        return [p]
    }

    /// Read `assets/runtimes/<n>/configuration.json` as a generic dict. Returns
    /// nil when the file is missing or unparseable.
    private static func runtimeConfigJSON(_ runtimeName: String) -> [String: Any]? {
        for base in assetsBases() {
            let path = "\(base)/runtimes/\(runtimeName)/configuration.json"
            guard let data = FileManager.default.contents(atPath: path),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { continue }
            return json
        }
        return nil
    }

    /// Read the fixed IP for a runtime from `assets/runtimes/<n>/configuration.json`.
    /// One PHP runtime exists at a time, one Node runtime, etc. — IPs are intrinsic
    /// to the runtime name, not allocated. Throws if the file or `ip` field is missing.
    static func runtimeIP(for runtimeName: String) throws -> String {
        guard let json = runtimeConfigJSON(runtimeName) else {
            throw RuntimeError("Runtime '\(runtimeName)' has no configuration.json in assets/runtimes/.")
        }
        if let ip = json["ip"] as? String, !ip.isEmpty {
            return ip
        }
        throw RuntimeError("Runtime '\(runtimeName)' configuration.json has no 'ip' field.")
    }

    /// Read the always-on sidecars for a runtime from its configuration.json
    /// `defaultSidecars` field. Empty array when the field is absent.
    /// Phase 9 trigger source for runtime-level sidecars (e.g. mailpit on PHP).
    static func runtimeDefaultSidecars(for runtimeName: String) -> [String] {
        guard let json = runtimeConfigJSON(runtimeName),
              let sidecars = json["defaultSidecars"] as? [String]
        else { return [] }
        return sidecars
    }
}

// MARK: - ProjectTypeConfiguration

struct ProjectTypeConfiguration {
    let assetsType: String        // which type dir has scripts (e.g. "moodle", "astro")
    let assetsRuntime: String     // runtime that owns assetsType (e.g. "php", "node")
    let sidecars: [String]        // sidecar roles this project type requires on its runtime pod
    let stopSystemd: Bool         // whether stop needs systemctl stop
    let nextSteps: [String]       // printed after `create` completes
}

// MARK: - JSON loading helpers

/// Find and load a JSON file for a project type.
/// Searches assets/runtimes/*/project_types/<type>/<fileName> across all asset bases.
/// Returns (data, runtimeName) where runtimeName is the parent runtime directory.
private func findProjectTypeJSON(_ fileName: String, type: String) throws -> (Data, String) {
    for base in ProjectType.assetsBases() {
        let runtimesDir = "\(base)/runtimes"
        guard let runtimes = try? FileManager.default.contentsOfDirectory(atPath: runtimesDir)
        else { continue }
        for rt in runtimes {
            let path = "\(runtimesDir)/\(rt)/project_types/\(type)/\(fileName)"
            if let data = FileManager.default.contents(atPath: path) {
                return (data, rt)
            }
        }
    }
    throw RuntimeError("Cannot find \(fileName) for project type '\(type)'.")
}

// MARK: - Configuration loading

extension ProjectType {

    /// Load configuration.json for this project type from the assets directory.
    func loadConfiguration() throws -> ProjectTypeConfiguration {
        guard !name.isEmpty else {
            throw RuntimeError("No project type specified.")
        }
        let (data, runtimeName) = try findProjectTypeJSON("configuration.json", type: name)
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw RuntimeError("Cannot parse configuration.json for project type '\(name)'.")
        }

        let assetsType = json["assetsType"] as? String ?? name
        let sidecars   = json["sidecars"]   as? [String] ?? []

        // Resolve assetsRuntime: if assetsType differs from name, find which runtime owns assetsType
        let assetsRuntime: String
        if assetsType != name {
            assetsRuntime = (try? findProjectTypeJSON("configuration.json", type: assetsType).1) ?? runtimeName
        } else {
            assetsRuntime = runtimeName
        }

        // Project-type specific knobs (PHP version, DB tag, etc.) are resolved
        // by configure.sh from the layered mpd.env files: synced mpd-user.env
        // at /srv/personal/mpd-user.env, then per-project /srv/projects/<n>/mpd.env
        // (project wins on duplicate keys).
        let stopObj       = json["stop"] as? [String: Any] ?? [:]
        let stopSystemd   = stopObj["systemdStop"] as? Bool ?? false

        let nextSteps     = json["nextSteps"] as? [String] ?? []

        return ProjectTypeConfiguration(
            assetsType: assetsType, assetsRuntime: assetsRuntime,
            sidecars: sidecars,
            stopSystemd: stopSystemd,
            nextSteps: nextSteps)
    }

}

