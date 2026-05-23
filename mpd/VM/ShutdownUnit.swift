// mpd — Mpd.VM.installShutdownUnit() implementation
//
// Installs a user-level systemd unit that brackets the VM lifecycle:
//   - At boot: runs `mpd --start` to reconcile current state toward
//     persisted intent (`requested`). Runtimes/projects with
//     `requested=running` come back up automatically.
//   - At shutdown / reboot / suspend: runs `mpd --stop` so DBs get a
//     graceful EventMpdPreStop hook firing instead of being SIGTERM'd
//     mid-flight by podman teardown.
//
// Why a user-level unit (not system-level): the privilege rule forbids
// identity switching (`sudo -u <user>`). mpd binary runs as the dev
// user, so the unit must too. `loginctl enable-linger <user>` keeps
// the user-systemd manager alive across logout — required for the
// unit to fire on unattended shutdowns and on boot.
// See AGENTS.md §"Mandatory privilege rule" + docs/HOOKS.md
// §"Systemd integration".

import Foundation

extension Mpd.VM {

    private static var unitDir: String {
        "\(Mpd.VM.homeDir)/.config/systemd/user"
    }

    private static var unitPath: String {
        "\(unitDir)/mpd.service"
    }

    /// Boot path: `ExecStart=-` (the leading dash) makes failures
    /// non-fatal so the unit still goes active and ExecStop fires on
    /// shutdown even if start hit a transient issue at boot. Worst case:
    /// the user runs `mpd --start` themselves; the graceful-shutdown
    /// path is never lost.
    ///
    /// The mpd binary path is the absolute `/opt/mpd/bin/mpd`. Hardcoded
    /// in the rendered unit so `cat ~/.config/systemd/user/mpd.service`
    /// shows the real path — far easier to debug when something goes wrong.
    private static func renderUnit(mpdBin: String) -> String {
        """
        [Unit]
        Description=mpd lifecycle (start on boot, graceful stop on shutdown)
        DefaultDependencies=no
        Before=shutdown.target reboot.target halt.target suspend.target

        [Service]
        Type=oneshot
        RemainAfterExit=yes
        ExecStart=-\(mpdBin) --start
        ExecStop=\(mpdBin) --stop
        TimeoutStartSec=300
        TimeoutStopSec=180

        [Install]
        WantedBy=default.target
        """
    }

    /// Install + enable the unit and turn linger on for the dev user.
    /// Idempotent — overwrites the unit and re-enables on every call.
    static func installShutdownUnit() throws {
        let user = Mpd.VM.detectUserAndUID().user
        let mpdBin = Mpd.VM.expectedExecutablePath
        let unitContent = renderUnit(mpdBin: mpdBin)
        let fm = FileManager.default

        try fm.createDirectory(atPath: unitDir, withIntermediateDirectories: true)
        try unitContent.write(toFile: unitPath, atomically: true, encoding: .utf8)

        // Reload + enable. `systemctl --user` runs against the calling user.
        _ = Mpd.VM.exec(["systemctl", "--user", "daemon-reload"])
        _ = Mpd.VM.exec(["systemctl", "--user", "enable", "mpd.service"])
        _ = Mpd.VM.exec(["systemctl", "--user", "start", "mpd.service"])

        // Linger so user-systemd survives logout — required for the unit
        // to fire on unattended shutdown (host-driven, cron, etc.) and
        // to start mpd at boot.
        _ = Mpd.VM.exec(["sudo", "loginctl", "enable-linger", user])
    }
}
