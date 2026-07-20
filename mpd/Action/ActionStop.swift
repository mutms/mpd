// mpd lifecycle command hooks
// VM stop behavior — powers off the VM.

import Foundation

extension Mpd.Action.Stop {
    static func execute() throws {
        guard FileManager.default.fileExists(atPath: Mpd.VM.stateDir) else {
            throw RuntimeError("mpd is not set up yet. Run: mpd --setup")
        }

        // This command has two callers, and they need opposite halves of
        // the work:
        //
        //   • a human typing `mpd --stop` — should power the VM off, and
        //     must NOT fire hooks, because powering off makes systemd stop
        //     mpd.service, whose ExecStop runs this same command again.
        //   • systemd's ExecStop during shutdown — should fire the hooks,
        //     and must NOT power off (it is already happening).
        //
        // Firing in both places ran `mpd-pre-stop` twice, the second time
        // against databases that were already shutting down.
        //
        // systemd sets INVOCATION_ID for every process it runs as a unit,
        // so the two cases tell themselves apart with no unit change and
        // nothing to migrate on existing VMs.
        let fromSystemd = !(ProcessInfo.processInfo.environment["INVOCATION_ID"] ?? "").isEmpty

        if fromSystemd {
            // Graceful DB shutdown. Without it the next boot finds postgres
            // doing crash recovery on first start. Failures are logged but
            // never block — `.continue` failure mode.
            step("Firing pre-stop hooks")
            try Mpd.Hooks.fire(EventMpdPreStop(), verb: "stop")
            return
        }

        // Project status is *preserved* across the reboot (persisted intent
        // model — see docs/HOOKS.md §"Resource lifecycle model"). Projects
        // marked running stay running in state, so the next `mpd --start`
        // restores them automatically.

        print("""

        \u{001B}[1;33mPowering off VM\u{001B}[0m
        (your SSH session will drop in a moment; pre-stop hooks fire during shutdown)
        """)

        // Test/dev escape hatch: setting MPD_STOP_DOES_NOT_SHUTDOWN_VM
        // lets agents (or anyone) exercise the post-`mpd --stop` flow
        // without losing the SSH session to a real poweroff. Use sparingly
        // — the whole point of `mpd --stop` is normally to power off.
        if let v = ProcessInfo.processInfo.environment["MPD_STOP_DOES_NOT_SHUTDOWN_VM"], !v.isEmpty {
            print("\nMPD_STOP_DOES_NOT_SHUTDOWN_VM is set — skipping VM poweroff.")
            return
        }

        // systemd will SIGTERM podman services (rootful containers get graceful
        // shutdown via the podman.service unit). Passwordless sudo is set up
        // by the platform bootstrap script so this doesn't prompt.
        let rc = Mpd.VM.exec(["sudo", "systemctl", "poweroff"])
        if rc != 0 {
            throw RuntimeError("Failed to power off VM (sudo systemctl poweroff returned \(rc)).")
        }
    }
}
