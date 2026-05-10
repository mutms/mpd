// mpd — IDE quick-launch link generator.
//
// Renders one launcher file per registered project into
// ~/.mpd/links/vscode/ so users can double-click a project to attach
// their IDE to the matching runtime container via Remote-SSH.
//
//   Linux:  .desktop file (Type=Application, Exec=xdg-open vscode://...)
//   macOS:  .webloc plist (URL key, opens via Launch Services)
//
// Self-healing: regenerated from current project state on every
// refreshCurrentStateCache trigger. `mpd delete` removes stale
// entries on the next refresh — no per-verb plumbing.
//
// Project types opt out via `"ideLinks": false` in configuration.json
// (e.g. cftunnel — runs `cloudflared`, no editable source).
//
// Phase 1 ships VS Code only. Phase 2 will add a sibling
// ~/.mpd/links/phpstorm/ once the Gateway URL format is pinned.

import Foundation

extension Mpd.Runtime.IdeLinks {
    /// Root directory for IDE link files. Per-user, machine-agnostic;
    /// rebuilt from the active machine's project list on every refresh.
    static var dir: String { "\(Mpd.Environment.dotMpdDir)/links" }

    /// VS Code subdirectory.
    static var vscodeDir: String { "\(dir)/vscode" }

    /// Best-effort regenerate. Never throws — diagnostic refresh must
    /// never block a user-visible action.
    static func refresh() {
        let fm = FileManager.default
        let user = NSUserName()
        let projects = Mpd.Runtime.State.loadProjects().projects

        var desired: [String: ProjectLink] = [:]
        for proj in projects {
            guard !proj.runtimeName.isEmpty, !proj.type.isEmpty else { continue }
            guard let cfg = try? ProjectType(proj.type).loadConfiguration(),
                  cfg.ideLinks else { continue }
            desired[proj.name] = ProjectLink(
                project: proj.name,
                runtime: proj.runtimeName,
                user: user)
        }

        try? fm.createDirectory(atPath: vscodeDir, withIntermediateDirectories: true)

        let ext = linkExtension
        if let existing = try? fm.contentsOfDirectory(atPath: vscodeDir) {
            for entry in existing where entry.hasSuffix(".\(ext)") {
                let base = String(entry.dropLast(ext.count + 1))
                if desired[base] == nil {
                    try? fm.removeItem(atPath: "\(vscodeDir)/\(entry)")
                }
            }
        }

        for (name, link) in desired {
            let path = "\(vscodeDir)/\(name).\(ext)"
            try? link.vscodeBody.write(toFile: path, atomically: true, encoding: .utf8)
            try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
        }
    }

    private static var linkExtension: String {
        #if os(macOS)
        return "webloc"
        #else
        return "desktop"
        #endif
    }
}

private struct ProjectLink {
    let project: String
    let runtime: String
    let user: String

    var vscodeURL: String {
        "vscode://vscode-remote/ssh-remote+\(user)@\(runtime).runtime.mpd.test/srv/projects/\(project)"
    }

    var vscodeBody: String {
        #if os(macOS)
        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
        \t<key>URL</key>
        \t<string>\(vscodeURL)</string>
        </dict>
        </plist>

        """
        #else
        return """
        [Desktop Entry]
        Type=Application
        Name=\(project)
        Comment=Open \(project) in VS Code (Remote-SSH into the runtime container)
        Exec=xdg-open \(vscodeURL)
        Icon=visual-studio-code
        Terminal=false
        NoDisplay=true
        Categories=Development;

        """
        #endif
    }
}
