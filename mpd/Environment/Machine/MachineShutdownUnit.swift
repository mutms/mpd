// mpd — Mpd.Environment systemd shutdown unit (Linux only)
//
// Installs a user-level systemd unit that runs `mpd --stop` before
// VM shutdown / reboot / suspend, so the DBs get a graceful
// EventMpdPreStop hook firing instead of being SIGTERM'd mid-flight by
// podman teardown.
//
// Why a user-level unit (not system-level): the privilege rule forbids
// identity switching (`sudo -u <user>`). mpd binary runs as the dev
// user, so the unit must too. `loginctl enable-linger <user>` keeps
// the user-systemd manager alive across logout — required for the
// unit to fire on unattended shutdowns (host-driven, cron, etc.).
// See AGENTS.md §"Mandatory privilege rule" + docs/HOOKS.md
// §"Systemd integration".

import Foundation

#if os(Linux)
extension Mpd.Environment {
    enum ShutdownUnit {}
}

extension Mpd.Environment.ShutdownUnit {

    private static var unitDir: String {
        "\(Mpd.Environment.homeDir)/.config/systemd/user"
    }

    private static var unitPath: String {
        "\(unitDir)/mpd.service"
    }

    static let unitContent = """
        [Unit]
        Description=mpd graceful shutdown
        DefaultDependencies=no
        Before=shutdown.target reboot.target halt.target suspend.target

        [Service]
        Type=oneshot
        RemainAfterExit=yes
        ExecStart=/bin/true
        ExecStop=/usr/local/bin/mpd --stop

        [Install]
        WantedBy=default.target
        """

    /// Install + enable the unit and turn linger on for the dev user.
    /// Idempotent — overwrites the unit and re-enables on every call.
    static func install() throws {
        let user = Mpd.Environment.detectUserAndUID().user
        let fm = FileManager.default

        try fm.createDirectory(atPath: unitDir, withIntermediateDirectories: true)
        try unitContent.write(toFile: unitPath, atomically: true, encoding: .utf8)

        // Reload + enable. `systemctl --user` runs against the calling user.
        _ = Mpd.Environment.HostExec.run(["systemctl", "--user", "daemon-reload"])
        _ = Mpd.Environment.HostExec.run(["systemctl", "--user", "enable", "mpd.service"])
        _ = Mpd.Environment.HostExec.run(["systemctl", "--user", "start", "mpd.service"])

        // Linger so user-systemd survives logout — required for the unit
        // to fire on unattended shutdown (host-driven, cron, etc.).
        _ = Mpd.Environment.HostExec.run(["sudo", "loginctl", "enable-linger", user])
    }

    /// Disable + stop the unit and remove the unit file. Linger is left
    /// alone — the user may have enabled it for other purposes, and an
    /// orphan linger flag is harmless when no user units exist.
    static func uninstall() {
        let fm = FileManager.default

        _ = Mpd.Environment.HostExec.run(["systemctl", "--user", "stop", "mpd.service"])
        _ = Mpd.Environment.HostExec.run(["systemctl", "--user", "disable", "mpd.service"])

        if fm.fileExists(atPath: unitPath) {
            try? fm.removeItem(atPath: unitPath)
            _ = Mpd.Environment.HostExec.run(["systemctl", "--user", "daemon-reload"])
        }
    }
}
#endif
