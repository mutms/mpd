// mpd — Mpd.TUI
// Terminal UI: runtime list → runtime detail → command list → execute

import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

extension Mpd { enum TUI {} }

// MARK: - Key input

private enum Key {
    case up, down, left, right, enter, escape, backspace
    case char(Character)
    case timeout
}

// MARK: - Terminal primitives

private var savedTermios = termios()

private func enableRawMode() {
    tcgetattr(STDIN_FILENO, &savedTermios)
    var raw = savedTermios
    raw.c_lflag &= ~(tcflag_t(ECHO) | tcflag_t(ICANON) | tcflag_t(ISIG))
    raw.c_iflag &= ~(tcflag_t(IXON) | tcflag_t(ICRNL))
    withUnsafeMutablePointer(to: &raw.c_cc) {
        $0.withMemoryRebound(to: cc_t.self, capacity: Int(NCCS)) {
            $0[Int(VMIN)]  = 0
            $0[Int(VTIME)] = 20   // 2 s timeout → auto-refresh
        }
    }
    tcsetattr(STDIN_FILENO, TCSAFLUSH, &raw)
}

private func disableRawMode() {
    tcsetattr(STDIN_FILENO, TCSAFLUSH, &savedTermios)
}

private func readKey() -> Key {
    var buf = [UInt8](repeating: 0, count: 8)
    let n = read(STDIN_FILENO, &buf, 8)
    guard n > 0 else { return .timeout }
    switch buf[0] {
    case 27:                                     // ESC or arrow sequence
        guard n >= 3, buf[1] == 91 else { return .escape }
        switch buf[2] {
        case 65: return .up
        case 66: return .down
        case 67: return .right
        case 68: return .left
        default: return .escape
        }
    case 13, 10: return .enter
    case 127:    return .backspace
    default:
        guard buf[0] >= 32, buf[0] < 127 else { return .timeout }
        return .char(Character(UnicodeScalar(buf[0])))
    }
}

// MARK: - ANSI

private let ESC = "\u{1B}"
private func out(_ s: String) { print(s, terminator: ""); fflush(stdout) }
private func enterAltScreen()  { out("\(ESC)[?1049h\(ESC)[?25l") }
private func exitAltScreen()   { out("\(ESC)[?25h\(ESC)[?1049l") }
private func clearScreen()     { out("\(ESC)[2J\(ESC)[H") }
private func moveTo(_ r: Int, _ c: Int) { out("\(ESC)[\(r);\(c)H") }
private func clearLine()       { out("\(ESC)[2K") }

private func bold(_ s: String)   -> String { "\(ESC)[1m\(s)\(ESC)[0m" }
private func dim(_ s: String)    -> String { "\(ESC)[2m\(s)\(ESC)[0m" }
private func green(_ s: String)  -> String { "\(ESC)[32m\(s)\(ESC)[0m" }
private func red(_ s: String)    -> String { "\(ESC)[31m\(s)\(ESC)[0m" }
private func yellow(_ s: String) -> String { "\(ESC)[33m\(s)\(ESC)[0m" }
private func rev(_ s: String)    -> String { "\(ESC)[7m\(s)\(ESC)[0m" }

private func termSize() -> (rows: Int, cols: Int) {
    var ws = winsize()
    if ioctl(STDOUT_FILENO, UInt(TIOCGWINSZ), &ws) == 0, ws.ws_row > 0, ws.ws_col > 0 {
        return (Int(ws.ws_row), Int(ws.ws_col))
    }
    return (24, 80)
}

private func fit(_ s: String, _ width: Int) -> String {
    s.count <= width
        ? s.padding(toLength: width, withPad: " ", startingAt: 0)
        : String(s.prefix(width - 1)) + "…"
}

// MARK: - Data model

private struct ProjectRow {
    let name: String
    let type: String          // "moodle", "astro", etc.
    let runtimeName: String   // joined from project record
    let databaseId: String    // e.g. "postgres-17", empty for node
    let databaseEngine: String
    let databaseVersion: String
    let status: String        // "running", "stopped", "not-configured"
    let urls: [ProjectURL]
    let mainURL: String       // empty for stopped — matches `mpd list` behavior
}

private struct RuntimeRow {
    let name: String
    let runtimeType: String   // "php", "node", "trixie"
    let ip: String
    let running: Bool
    let projectCount: Int
}

/// All projects across all runtimes, sorted by name. The top-screen view
/// for the projects-first TUI.
private func loadProjects() -> [ProjectRow] {
    return Mpd.Runtime.State.loadProjects().projects
        .sorted { $0.name < $1.name }
        .map { p in
            ProjectRow(
                name: p.name,
                type: p.type,
                runtimeName: p.runtimeName,
                databaseId: p.databaseId,
                databaseEngine: p.databaseEngine,
                databaseVersion: p.databaseVersion,
                status: p.requested.rawValue,
                urls: p.urls,
                mainURL: Mpd.Project.projectURL(entry: p)
            )
        }
}

/// All runtime containers — the auxiliary screen.
private func loadRuntimes() -> [RuntimeRow] {
    let projects = Mpd.Runtime.State.loadProjects().projects
    return Mpd.Runtime.allContainers()
        .sorted { ($0.Labels?["mpd.name"] ?? "") < ($1.Labels?["mpd.name"] ?? "") }
        .map { item in
            let name        = item.Labels?["mpd.name"]    ?? item.Names.first ?? "?"
            let runtimeType = item.Labels?["mpd.runtime"] ?? "-"
            let ip          = item.Labels?["mpd.ip"] ?? Mpd.Podman.containerIP(item.Names.first ?? "")
            let running     = item.State == "running"
            let count       = projects.filter { $0.runtimeName == name }.count
            return RuntimeRow(name: name, runtimeType: runtimeType,
                              ip: ip, running: running, projectCount: count)
        }
}

// MARK: - TUI commands

private struct TUICommand {
    let label: String
    let needsConfirm: Bool
    let inputPrompt: String?    // non-nil → show text field before running/confirming
    let inputDefault: String
    let run: (_ input: String) throws -> Bool   // true = exit TUI after running
}

private func cmd(_ label: String, confirm: Bool = false,
                 run: @escaping (_ input: String) throws -> Bool) -> TUICommand {
    TUICommand(label: label, needsConfirm: confirm,
               inputPrompt: nil, inputDefault: "", run: run)
}

private func runtimeCommands(_ rt: RuntimeRow) -> [TUICommand] {[
    cmd(rt.running ? "Stop runtime" : "Start runtime") { _ in
        if rt.running { try Mpd.Runtime.stop(rt.name) }
        else          { try Mpd.Runtime.start(rt.name) }
        return false
    },
]}

private func projectCommands(_ proj: ProjectRow) -> [TUICommand] {
    let cName  = Mpd.Runtime.containerName(proj.runtimeName)
    let pType  = ProjectType(proj.type)
    let config = try? pType.loadConfiguration()
    let assetsType = config?.assetsType ?? proj.type

    var cmds: [TUICommand] = []

    // Systemd service controls (from configuration.json: stop.systemdStop)
    if config?.stopSystemd ?? false {
        cmds.append(cmd("Start")   { _ in Mpd.Podman.exec(cName, ["systemctl", "start",   "mpd-\(proj.name)"]); return false })
        cmds.append(cmd("Stop")    { _ in Mpd.Podman.exec(cName, ["systemctl", "stop",    "mpd-\(proj.name)"]); return false })
        cmds.append(cmd("Restart") { _ in Mpd.Podman.exec(cName, ["systemctl", "restart", "mpd-\(proj.name)"]); return false })
    }

    // Configure with DB input (if type has a configure.sh script)
    if let assetsDir = try? Mpd.Core.Assets.path(),
       FileManager.default.fileExists(atPath: "\(assetsDir)/runtimes/\(config?.assetsRuntime ?? "")/project_types/\(assetsType)/scripts/configure.sh") {
        let databaseId = proj.databaseId.isEmpty ? "" : proj.databaseId
        cmds.append(TUICommand(label: "Configure", needsConfirm: false,
                   inputPrompt: "Database ID", inputDefault: databaseId) { input in
            let db = input.isEmpty ? databaseId : input
            Mpd.Podman.execInteractive(cName, ["bash",
                "/mnt/assets/runtimes/\(config?.assetsRuntime ?? "")/project_types/\(assetsType)/scripts/configure.sh", proj.name, db])
            return true
        })
    }

    // Project-type-specific operations are tools (run inside the runtime
    // container via SSH, not exposed as host-side verbs); see ARCHITECTURE.md §7.

    return cmds
}

// MARK: - Screen

private enum BackTarget {
    case projectList
    case runtimeList
}

private enum Screen {
    case projectList   // top: all projects across all runtimes
    case runtimeList   // auxiliary: runtime-level view (start/stop runtime)
    case commandList(cmds: [TUICommand], title: String, back: BackTarget)
    case confirmRun(cmd: TUICommand, input: String, cmds: [TUICommand], cmdTitle: String, back: BackTarget)
    case textInput(cmd: TUICommand, cmds: [TUICommand], cmdTitle: String, back: BackTarget)
}

// MARK: - Run loop

extension Mpd.TUI {

    static func run() {
        var projects = loadProjects()
        var runtimes = loadRuntimes()
        var projIdx  = 0
        var rtIdx    = 0
        var cmdIdx   = 0
        var inputBuf = ""
        var message  = ""
        var screen: Screen = .projectList

        enterAltScreen()
        enableRawMode()
        defer { disableRawMode(); exitAltScreen() }

        func clamp(_ v: Int, _ n: Int) -> Int { n == 0 ? 0 : max(0, min(v, n - 1)) }

        // ── Rendering ─────────────────────────────────────────────────

        func draw() {
            let (rows, cols) = termSize()
            clearScreen()

            func header(_ title: String) {
                moveTo(1, 1); out(bold(fit(title, cols)))
                moveTo(2, 1); out(dim(String(repeating: "─", count: cols)))
            }
            func hintBar(_ hint: String) {
                moveTo(3, 1); out(dim(fit(hint, cols)))
                moveTo(4, 1); out(dim(String(repeating: "─", count: cols)))
            }

            let contentStart = 5
            let contentRows  = max(1, rows - contentStart - 1)

            switch screen {

            case .projectList:
                header("mpd — Moodle Plugin Development Environment")
                hintBar("↑↓ select   → commands   r runtimes   ESC quit")
                if projects.isEmpty {
                    moveTo(contentStart, 3)
                    out(dim("No projects yet.  Run: mpd create <project>"))
                } else {
                    moveTo(contentStart, 1)
                    out(dim(fit("  PROJECT", 16) + fit("STATUS", 10) +
                            fit("TYPE", 10) + fit("RUNTIME", 10) +
                            fit("DB", 16) + "URL"))
                    for (i, p) in projects.prefix(contentRows - 1).enumerated() {
                        moveTo(contentStart + 1 + i, 1)
                        let dbInfo  = p.databaseId.isEmpty ? "-" : p.databaseId
                        // mainURL is empty for stopped projects (matches `mpd list`).
                        let extras  = p.mainURL.isEmpty ? 0 : max(0, p.urls.count - 1)
                        let urlField = p.mainURL + (extras > 0 ? "  (+\(extras))" : "")
                        let row = "  " + fit(p.name, 14) + fit(p.status, 10) +
                                  fit(p.type, 10) + fit(p.runtimeName, 10) +
                                  fit(dbInfo, 16) + urlField
                        out(i == projIdx ? rev(fit(row, cols)) : row)
                    }
                }

            case .runtimeList:
                header("Runtimes (auxiliary)")
                hintBar("↑↓ select   → commands   ESC projects")
                if runtimes.isEmpty {
                    moveTo(contentStart, 3)
                    out(dim("No runtimes found.  Run: mpd --runtime-create=<name>"))
                } else {
                    moveTo(contentStart, 1)
                    out(dim(fit("  NAME", 18) + fit("TYPE", 8) + fit("IP", 16) +
                            fit("STATUS", 10) + "PROJECTS"))
                    for (i, rt) in runtimes.prefix(contentRows - 1).enumerated() {
                        moveTo(contentStart + 1 + i, 1)
                        let status = rt.running ? "running" : "stopped"
                        let pLabel = "\(rt.projectCount) project\(rt.projectCount == 1 ? "" : "s")"
                        let row    = "  " + fit(rt.name, 16) + fit(rt.runtimeType, 8) +
                                     fit(rt.ip, 16) + fit(status, 10) + pLabel
                        out(i == rtIdx ? rev(fit(row, cols)) : row)
                    }
                }

            case .commandList(let cmds, let title, _):
                header(title)
                hintBar("↑↓ select   ↵ execute   ← / ESC back")
                for (i, c) in cmds.prefix(contentRows).enumerated() {
                    moveTo(contentStart + i, 1)
                    let row = "  " + c.label
                    out(i == cmdIdx ? rev(fit(row, cols)) : row)
                }

            case .confirmRun(let c, _, _, _, _):
                header("Confirm")
                hintBar("y execute   n / ESC cancel")
                moveTo(contentStart,     3); out(yellow(c.label))
                moveTo(contentStart + 2, 3)
                out("Execute?  " + bold("[y]") + " yes   " + bold("[n]") + " / " +
                    bold("[ESC]") + " cancel")

            case .textInput(let c, _, _, _):
                header("Input required")
                hintBar("type value   ↵ confirm   ESC cancel")
                moveTo(contentStart,     3); out(yellow(c.label))
                moveTo(contentStart + 2, 3); out((c.inputPrompt ?? "Value") + ":")
                moveTo(contentStart + 3, 5); out(bold(inputBuf) + "▌")
                moveTo(contentStart + 5, 3); out(dim("Enter to confirm   ESC to cancel"))
            }

            moveTo(rows, 1); clearLine()
            if !message.isEmpty { out(dim(message)) }
            fflush(stdout)
        }

        // ── Restore a back target to a Screen ─────────────────────────

        func restore(_ back: BackTarget) -> Screen {
            switch back {
            case .projectList: return .projectList
            case .runtimeList: return .runtimeList
            }
        }

        // ── Execute a command (temporarily exits TUI for interactive output) ──

        func execute(_ c: TUICommand, input: String, back: BackTarget) {
            disableRawMode()
            exitAltScreen()
            do {
                let exits = try c.run(input)
                projects = loadProjects()
                runtimes = loadRuntimes()
                if exits {
                    print(dim("\nPress Enter to return to mpd TUI…"), terminator: "")
                    fflush(stdout)
                    _ = readLine()
                }
            } catch {
                print(red("\nError: \(error.localizedDescription)"))
                print(dim("Press Enter to continue…"), terminator: "")
                fflush(stdout)
                _ = readLine()
                projects = loadProjects()
                runtimes = loadRuntimes()
            }
            enterAltScreen()
            enableRawMode()
            projIdx = clamp(projIdx, projects.count)
            rtIdx = clamp(rtIdx, runtimes.count)
            message = "Done."
            screen = restore(back)
        }

        // ── Main loop ──────────────────────────────────────────────────

        while true {
            draw()
            let key = readKey()

            if case .timeout = key {
                projects = loadProjects()
                runtimes = loadRuntimes()
                projIdx = clamp(projIdx, projects.count)
                rtIdx = clamp(rtIdx, runtimes.count)
                continue
            }

            message = ""

            switch screen {

            // ── Project list (top) ─────────────────────────────────────
            case .projectList:
                switch key {
                case .up:   projIdx = clamp(projIdx - 1, projects.count)
                case .down: projIdx = clamp(projIdx + 1, projects.count)
                case .right, .enter:
                    if let p = projects[safe: projIdx] {
                        cmdIdx = 0
                        screen = .commandList(cmds: projectCommands(p),
                                              title: "\(p.name)  in  \(p.runtimeName)",
                                              back: .projectList)
                    }
                case .char("r"), .char("R"):
                    rtIdx = 0
                    screen = .runtimeList
                case .escape:
                    return
                default: break
                }

            // ── Runtime list (auxiliary) ───────────────────────────────
            case .runtimeList:
                switch key {
                case .up:   rtIdx = clamp(rtIdx - 1, runtimes.count)
                case .down: rtIdx = clamp(rtIdx + 1, runtimes.count)
                case .right, .enter:
                    if let rt = runtimes[safe: rtIdx] {
                        cmdIdx = 0
                        screen = .commandList(cmds: runtimeCommands(rt),
                                              title: "Runtime: \(rt.name)",
                                              back: .runtimeList)
                    }
                case .escape, .left:
                    screen = .projectList
                default: break
                }

            // ── Command list ───────────────────────────────────────────
            case .commandList(let cmds, let title, let back):
                switch key {
                case .up:   cmdIdx = clamp(cmdIdx - 1, cmds.count)
                case .down: cmdIdx = clamp(cmdIdx + 1, cmds.count)
                case .left, .escape:
                    screen = restore(back)
                case .enter:
                    guard let c = cmds[safe: cmdIdx] else { break }
                    if c.inputPrompt != nil {
                        inputBuf = c.inputDefault
                        screen = .textInput(cmd: c, cmds: cmds, cmdTitle: title, back: back)
                    } else if c.needsConfirm {
                        screen = .confirmRun(cmd: c, input: "", cmds: cmds, cmdTitle: title, back: back)
                    } else {
                        execute(c, input: "", back: back)
                    }
                default: break
                }

            // ── Confirm ────────────────────────────────────────────────
            case .confirmRun(let c, let input, let cmds, let title, let back):
                switch key {
                case .char("y"), .char("Y"):
                    execute(c, input: input, back: back)
                case .char("n"), .char("N"), .escape:
                    screen = .commandList(cmds: cmds, title: title, back: back)
                default: break
                }

            // ── Text input ─────────────────────────────────────────────
            case .textInput(let c, let cmds, let title, let back):
                switch key {
                case .char(let ch):
                    inputBuf.append(ch)
                case .backspace:
                    if !inputBuf.isEmpty { inputBuf.removeLast() }
                case .enter:
                    let val = inputBuf; inputBuf = ""
                    if c.needsConfirm {
                        screen = .confirmRun(cmd: c, input: val, cmds: cmds, cmdTitle: title, back: back)
                    } else {
                        screen = .commandList(cmds: cmds, title: title, back: back)
                        execute(c, input: val, back: back)
                    }
                case .escape:
                    inputBuf = ""
                    screen = .commandList(cmds: cmds, title: title, back: back)
                default: break
                }
            }
        }
    }
}

// MARK: - Safe array subscript

private extension Array {
    subscript(safe i: Int) -> Element? {
        indices.contains(i) ? self[i] : nil
    }
}
