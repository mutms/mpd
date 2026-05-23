// mpd — shell completion shim installer.
//
// Sibling to Complete.swift. While Complete.swift emits candidates for
// `mpd --complete` (called at every Tab press), this file installs the
// shell-side shim that triggers those calls. Two consumers, one
// namespace: `Mpd.Completion.install()` and `Mpd.Completion.emit()`.
//
// Operates on the user's shell config (~/.zsh/completions/_mpd or
// ~/.bash_completion.d/mpd, plus a one-line sourcing snippet in ~/.zshrc
// or ~/.bashrc). Not "mpd state" — per-user shell ergonomics.

import Foundation

extension Mpd.Completion {

    /// Install a shell-completion shim matching the user's `$SHELL`. Both
    /// shims forward to `mpd --complete` (see Complete.swift); the shim
    /// itself is small and stable.
    static func install() {
        let userShell = ProcessInfo.processInfo.environment["SHELL"] ?? ""
        if userShell.hasSuffix("/zsh") {
            installZshCompletion()
        } else if userShell.hasSuffix("/bash") {
            installBashCompletion()
        } else {
            print("  Completion skipped — SHELL=\(userShell.isEmpty ? "(unset)" : userShell).")
        }
    }

    // MARK: - zsh

    private static func installZshCompletion() {
        let homeDir = Mpd.VM.homeDir
        let completionsDir = "\(homeDir)/.zsh/completions"
        let completionFile = "\(completionsDir)/_mpd"
        let zshrcPath = "\(homeDir)/.zshrc"
        let fm = FileManager.default

        guard let scriptSrc = sourcePath(named: "_mpd") else { return }
        guard let script = try? String(contentsOfFile: scriptSrc, encoding: .utf8) else {
            print("Warning: completion shim not found at \(scriptSrc)")
            return
        }

        do {
            if !fm.fileExists(atPath: completionsDir) {
                try fm.createDirectory(atPath: completionsDir, withIntermediateDirectories: true)
            }
            try script.write(toFile: completionFile, atomically: true, encoding: .utf8)
        } catch {
            print("Warning: cannot write \(completionFile): \(error.localizedDescription)")
            return
        }
        ok("zsh completion installed at ~/.zsh/completions/_mpd")

        if let files = try? fm.contentsOfDirectory(atPath: homeDir) {
            for f in files where f.hasPrefix(".zcompdump") {
                try? fm.removeItem(atPath: "\(homeDir)/\(f)")
            }
        }

        let currentZshrc = (try? String(contentsOfFile: zshrcPath, encoding: .utf8)) ?? ""
        if !currentZshrc.contains("~/.zsh/completions") {
            let hasCompinit = currentZshrc.contains("compinit")
            var block = "\n# mpd completions (added by mpd --setup)\nfpath=(~/.zsh/completions $fpath)\n"
            if !hasCompinit { block += "autoload -Uz compinit && compinit\n" }
            appendOrCreate(zshrcPath, content: block)
            ok("Updated ~/.zshrc with fpath=(~/.zsh/completions $fpath)")
        } else {
            print("  ~/.zshrc already includes ~/.zsh/completions in fpath.")
        }
        print("  Run 'exec zsh' to activate completions.")
    }

    // MARK: - bash

    private static func installBashCompletion() {
        let homeDir = Mpd.VM.homeDir
        let dropDir = "\(homeDir)/.bash_completion.d"
        let dropFile = "\(dropDir)/mpd"
        let bashrcPath = "\(homeDir)/.bashrc"
        let fm = FileManager.default

        guard let scriptSrc = sourcePath(named: "mpd.bash") else { return }
        guard let script = try? String(contentsOfFile: scriptSrc, encoding: .utf8) else {
            print("Warning: completion shim not found at \(scriptSrc)")
            return
        }

        do {
            if !fm.fileExists(atPath: dropDir) {
                try fm.createDirectory(atPath: dropDir, withIntermediateDirectories: true)
            }
            try script.write(toFile: dropFile, atomically: true, encoding: .utf8)
        } catch {
            print("Warning: cannot write \(dropFile): \(error.localizedDescription)")
            return
        }
        ok("bash completion installed at ~/.bash_completion.d/mpd")

        // Source the drop-in from .bashrc once. Sentinel comment makes the
        // block idempotent.
        let sentinel = "# mpd completions (added by mpd --setup)"
        let currentBashrc = (try? String(contentsOfFile: bashrcPath, encoding: .utf8)) ?? ""
        if !currentBashrc.contains(sentinel) {
            let block = """

            \(sentinel)
            if [ -f ~/.bash_completion.d/mpd ]; then . ~/.bash_completion.d/mpd; fi

            """
            appendOrCreate(bashrcPath, content: block)
            ok("Updated ~/.bashrc to source ~/.bash_completion.d/mpd")
        } else {
            print("  ~/.bashrc already sources ~/.bash_completion.d/mpd.")
        }
        print("  Run 'exec bash' (or open a new shell) to activate completions.")
    }

    // MARK: - Shared helpers

    private static func sourcePath(named filename: String) -> String? {
        guard let assetsPath = try? Mpd.VM.assetsPath() else {
            print("Warning: cannot resolve assets path for completion installation.")
            return nil
        }
        return "\(assetsPath)/completions/\(filename)"
    }

    private static func appendOrCreate(_ path: String, content: String) {
        let fm = FileManager.default
        if fm.fileExists(atPath: path), let fh = FileHandle(forWritingAtPath: path) {
            fh.seekToEndOfFile()
            if let data = content.data(using: .utf8) {
                fh.write(data)
            }
            fh.closeFile()
        } else {
            try? content.write(toFile: path, atomically: true, encoding: .utf8)
        }
    }
}
