# `util` runtime

Bare Debian Trixie — nothing on top of the runtime base. No language
stack, no FPM, no nvm by default. The developer SSHes in and installs
whatever they need (`apt`, `npm`, `pip`, …).

`runtime-base/tools/` (`claude-install`, `node-install`) are still on
PATH so the dev can layer Node or Claude Code on demand.

Project type: `bare` — accepts any directory under `/srv/projects/`
without imposing structure.
