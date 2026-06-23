// mpd — Shared output helpers, error type, and prompt utilities.
//
// `step()` / `ok()` / `errPrint()` are the standard logging primitives
// used everywhere in mpd's Swift code (matches the visual style of
// shell scripts under `assets/`). Use them for user-facing progress
// output instead of `print` + manual ANSI codes.
//
// `RuntimeError` is the standard thrown error type. Its
// `errorDescription` flows directly to stderr via ArgumentParser's
// error handling; keep messages actionable + include a next-step hint
// when possible (see CLI_BEHAVIOR.md "Behavioral invariants").
//
// `promptYesNo` is the only shell-level user prompt. Destructive
// operations should accept `--yes` to skip the prompt for scripted
// use (see CLI_BEHAVIOR.md "Behavioral invariants").
//
// Container/host command execution does NOT live here — that's
// `Mpd.Podman.*` (containers) and `Mpd.VM.*` (host
// binaries). See `docs/ARCHITECTURE.md` §3.

import Foundation
import Glibc

/// When true, *Quietly methods show full output (set by --debug flag).
var debugMode = false

// MARK: - Shell utilities

func step(_ msg: String) { print("\n\u{001B}[1m==> \(msg)\u{001B}[0m") }
func ok(_ msg: String)   { print("\u{001B}[1;32m✓ \(msg)\u{001B}[0m") }

/// Write a message to stderr.
func errPrint(_ msg: String) {
    FileHandle.standardError.write(Data((msg + "\n").utf8))
}

// MARK: - Error type

struct RuntimeError: LocalizedError {
    let errorDescription: String?
    init(_ message: String) { errorDescription = message }
}


// MARK: - Prompt helpers

func promptYesNo(_ message: String, defaultYes: Bool = false) -> Bool {
    let suffix = defaultYes ? "[Y/n]" : "[y/N]"
    print("\n\(message) \(suffix) ", terminator: "")
    let input = (readLine() ?? "").trimmingCharacters(in: .whitespaces).lowercased()
    if input.isEmpty { return defaultYes }
    return input == "y" || input == "yes"
}
