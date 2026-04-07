// mpd — Mpd.Core.PersonalArea namespace
// Provisions /srv/personal/ on the data volume — shared developer state
// (.ssh/, etc.) symlinked into runtime container homes by
// assets/runtime-base/bootstrap.sh.
//
// mpd-user.env is NOT staged here: it lives on the host at ~/.mpd/mpd-user.env
// and is synced into /srv/personal/mpd-user.env by syncBindMountFiles() at
// --setup/--start time. Runtimes read it via the /srv volume mount; a
// per-runtime symlink at $HOME/mpd-user.env points at the volume copy.
//
// Layout is flat (no per-user subdirectory) — runtimes are single-user.

import Foundation

extension Mpd.Core.PersonalArea {

    /// Provision /srv/personal/ on the data volume:
    ///   - ensure directory exists, owned by the dev uid (volume-tool execs
    ///     run as $EXTUID, so mkdir creates the tree owned automatically)
    ///   - ensure .ssh/ subdirectory exists for shared known_hosts
    static func provision() throws {
        let personalDir = "/srv/personal"

        guard Mpd.Podman.volumeToolRun(command: [
            "mkdir", "-p", "\(personalDir)/.ssh"
        ]) == 0 else {
            throw RuntimeError("Failed to create \(personalDir) in data volume.")
        }

        ok("Personal area ready at \(personalDir).")
    }
}
