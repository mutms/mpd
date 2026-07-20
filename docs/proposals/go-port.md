# Proposal: port the mpd binary from Swift to Go

**Status:** proposed
**Scope:** the `mpd` control-plane binary only — `assets/` and `bootstrap/` are untouched
**Migration:** two binaries side by side, then a flag day at the end

## Why

Go replaces Swift as mpd's implementation language, matching
[`mudev`](https://github.com/mutms/mudev) so the two projects share one
toolchain, one set of conventions, and one mental model. Practical wins:
faster builds, static binaries, a standard test story, and no
swiftlang dependency in the VM (a ~400 MB apt fetch, and the single
largest thing bootstrap downloads).

## What actually moves

Only the control plane. Every runtime, project type, and tool is shell
under `assets/`, invoked through the same interfaces before and after —
so the port cannot change what a project *is*, only how mpd orchestrates
it. That bounds the work sharply:

| Area | Lines | Notes |
|---|---|---|
| `Runtime/` | 3059 | biggest surface; runtime + project + DB + sidecars |
| `VM/` | 1150 | paths, exec, certs, DNS, platform identity |
| `Action/` | 820 | setup / start / stop / restart / status |
| `Service/` | 814 | dnsmasq, portal, adminer, fileaccess |
| `Hooks/` | 684 | typed events + `hooks/<event>.d/` dispatch |
| `CLI/` | 550 | handlers, status rendering, completion |
| `Util/` | 485 | Podman gateway |
| root (`Mpd.swift`, `Net.swift`, `main.swift`) | 854 | |
| `TUI/` | 493 | **not ported — deleted** |
| **total** | **9000** | 51 files, one dependency (swift-argument-parser) |

Two structural facts make this much easier than 9k lines suggests:

1. **Process execution is already a single choke point.** `Process()`
   appears only in `mpd/VM/Exec.swift`; everything else goes through
   `Mpd.Podman` or `Mpd.VM.exec`. mudev's `internal/exec` is the same
   pattern and explicitly cites this rule, so the port is a swap, not a
   redesign.
2. **Addressing is one module.** `Mpd.Net` replaced ~165 scattered
   literals, so the Go side has one file to translate carefully instead
   of 120 chances to fluff a string.

Foundation usage is shallow and mechanical: ~70 `FileManager` calls →
`os`, 15 JSON calls → `encoding/json`, 1 `NSRegularExpression` →
`regexp`, 6 `Thread.sleep` → `time.Sleep`.

## Decisions

**The TUI is deleted, not ported.** Its replacement is a Go web server
in the mpd binary — authenticated and write-capable, taking over what
the read-only portal does today. That is a separate project with its own
security design; this proposal only has to not block it. (One note for
whoever builds it, carried over from the addressing proposal: bind to
the bridge gateway `10.163.<id>.1`, not `MPD_VM_IP`. The gateway is the
VM itself, sits inside the already-routed /24, and is unreachable from
the rest of the LAN.)

Deleting the TUI has three visible consequences, all needing a decision
before Phase 1 lands:

- **Bare `mpd` currently launches the TUI** (`docs/CLI_BEHAVIOR.md`
  §1). Proposed replacement: bare `mpd` behaves as `mpd list`, which is
  already the default subcommand.
- **`--tui` disappears** from the flag set and from
  `mpd/CLI/Complete.swift`.
- **The sandbox GNOME launcher runs `mpd --tui`**
  (`setup/sandbox/lib/provision.sh`, and `setup/sandbox/README.md`
  documents it). It needs to become a terminal that lands in a shell, or
  point at the web UI once that exists.

**Tests are written during the port, not retrofitted.** Swift mpd has no
tests at all — no `Tests/`, no XCTest. Retrofitting them now would be
work thrown away. Writing them as each package lands means the Go
version is the first testable mpd, and the tests double as the
specification for behaviour currently defined only by the Swift source.

**The Go tree lives under `/opt/mpd/go/`.** Swift keeps `mpd/` and
`Package.swift` at the repo root until the flag day; Go gets its own
subtree so the two toolchains never scan each other's files. Layout
inside it follows mudev, so moving between the two repos costs nothing:

```
go/go.mod                  module github.com/mutms/mpd/go
go/cmd/mpd/main.go         entry point
go/internal/exec/          the ONLY package importing os/exec
go/internal/<domain>/      net, podman, runtime, project, service, hooks, vm…
go/internal/<domain>/*_test.go   beside the source, stdlib `testing`
```

Build output still lands in `/opt/mpd/bin/` — that is where
`Mpd.VM.binDir` points and where the finished binary has to be, so the
Go build writes `bin/gompd` during the transition and `bin/mpd` after
the rename.

Two integration details this creates:

- **`Package.swift` must exclude `go`.** It uses `path: "."` with an
  explicit `sources: ["mpd"]` and an `exclude:` list; add `"go"` there
  so SwiftPM never considers the subtree.
- **The root `Makefile` gains Go targets** that delegate into `go/`
  (`go-build`, `go-test`, `go-vet`, `go-fmt-check`), leaving the
  existing `build` / `install` on Swift until Phase 4 swaps them.

Dependencies: `cobra` for the CLI (replacing swift-argument-parser).
Add others only with a reason.

## Sequencing

**Everything except `--setup` first; `--setup` last, on a throwaway VM.**

`--setup` is the most destructive and least reversible action — it
creates the Podman network, generates the CA and service certs,
configures the host resolver, and installs system units. It is also the
one action whose failure leaves a VM in a half-built state. Porting it
last means every other verb is already proven against real containers by
the time it runs, and it can be validated on a VM that is worth nothing.

### Phase 0 — skeleton

`cmd/mpd`, `internal/exec`, `internal/net`, `internal/podman`, plus the
Makefile and CI-shaped targets. Build as **`gompd`**: a second binary,
installed alongside Swift `mpd`, no conflict.

Gotchas that will bite on day one:

- `enforceExpectedExecutableLocation()` hard-codes `/opt/mpd/bin/mpd`;
  `gompd` needs its own gate or it refuses to run at all.
- The `Makefile` has a single `install` target assuming `swift build`.
- The completion shim calls `mpd --complete`.

### Phase 1 — read-only verbs

`list`, `status`, `show`, `--runtime`, plus completion. No writes.

**Verification: differential testing against the Swift binary.** Run the
same command through both and diff the output. This is exactly the
technique that proved the `Mpd.Net` refactor was a no-op (89 lines of
identical output across 8 commands), and it substitutes for the unit
tests Swift mpd never had — a stronger check than unit tests would have
been, because it compares against known-good behaviour rather than
against someone's belief about it.

### Testing against a live VM

Dogfood the tool: an mpd VM is disposable by design, so develop mpd
against a real one and create, start, stop and delete freely. Reset is
`mpd --setup`, or deleting the VM.

This is not a nicety. Two bugs in the first read-only increment were
invisible against an empty VM and appeared immediately once fixtures
existed:

- A `podman ps` filter that matched nothing (`label=mpd.type=runtime`;
  runtime containers actually carry `mpd.runtime=<name>`). An empty
  result renders exactly like "nothing to show".
- `current` rendered as a copy of `requested`, which only diverges once
  a project exists in a state where intent and observation differ.

So diff each ported verb across several states, not one: nothing
created, created but not configured, running, and stopped. Keep a
project and a DB container around as fixtures — a difftest against an
empty VM proves very little.

### Phase 2 — mutating verbs, one at a time

Runtime and project lifecycle, DB verbs, services, hooks. After each:
compare the state files (`projects.json`, `databases.json`,
`current-state.json`, `runtimes/<n>/meta.json`) before and after, and
confirm the Swift binary still reads them correctly.

**Only one binary writes at any time.** Two writers with subtly
different JSON serialisation is the failure mode that eats a weekend —
the shared contract is the state files, podman labels, and container
names, and it is only safe while exactly one implementation is
authoritative.

### Status (2026-07-21)

Ported and verified byte-for-byte against the Swift binary: `list` (all
four), `show`, `runtime` show/create/start/stop/delete, `db`
create/start/stop/delete, `project` create/configure/start/stop/delete,
`net`, `version`, `check-hooks`, `--start`, `--stop`, `--restart`, plus
`internal/hooks` and `internal/sidecar`.

Harnesses: `make go-difftest` (12 read-only comparisons) and
`make go-mutatetest` (17 state comparisons). Both must stay green.

`--setup` is now ported too (`internal/cli/setup.go`, `internal/vm/`,
`internal/service/`). Verified on VM 150 in two ways:

- **Idempotent path** — `mpd --setup` then `gompd setup` on a settled VM
  produce byte-identical transcripts.
- **Reset path** — the migration reset, run for real:

  ```
  sudo podman rm -af
  sudo podman pod rm -af
  sudo podman network rm mpd-internal
  gompd setup
  ```

  Rebuilt the network, all four service containers, the DNS records and
  the VM metadata in 5 seconds, recovered the project list from the data
  volume, and left the portal answering 200 over HTTPS at the zone apex
  with a valid certificate (`curl` without `-k`).

Two deliberate divergences from Swift, both documented at their call
sites:

- **Service registry order** drives the line order of `services.conf`.
  Go's registry was reordered to match Swift's so the file comes out
  byte-identical and neither binary restarts dnsmasq after the other.
- **The Firefox policy JSON** is rendered by Go's marshaller
  (`"key": value`) rather than Foundation's (`"key" : value`). Both are
  valid and Firefox reads either, but each binary rewrites the other's
  file once. Self-corrects at the flag day.

### Phase 3 — `--setup`, on a fresh VM

Port `--setup` / `--start` / `--stop` / `--restart`. Validate by
bootstrapping a brand-new VM with Go mpd only — no Swift binary present.
Success is a VM that reaches "portal answers over HTTPS at the zone
apex" without a Swift toolchain ever being installed.

### Phase 4 — flag day

Rename `gompd` → `mpd`; delete `mpd/`, `Package.swift`,
`Package.resolved`, and `.build/`; drop `swiftlang` from
`bootstrap/40-install-software.sh`; point `make build` / `make install`
at the Go targets; update completions, `docs/ARCHITECTURE.md` code-layout
section, `AGENTS.md`, and `docs/CLI_BEHAVIOR.md`.

Whether `go/` then gets promoted to the repo root is a separate,
purely cosmetic decision — leaving it in place costs nothing and avoids
a large no-op diff.

## Risks

- **No behavioural spec.** Swift mpd's behaviour is defined by its
  source. Phase 1's output diffing and Phase 2's state-file comparison
  are the mitigation; anything not covered by a verb comparison needs a
  test written from reading the Swift.
- **Error messages are part of the UX.** Several carry fix-it
  instructions users follow verbatim (the identity error, the network
  subnet guard, the bootstrap-incomplete hint). Port the text, not just
  the condition.
- **Hooks are a public contract.** `assets/hooks/<event>.d/` scripts and
  the `Event` catalogue are consumed by assets outside the binary;
  `--check-hooks` cross-references them. The event names and payloads
  must survive the port unchanged.
- **Long tail of small platform details** — sudo invocations, systemd
  unit installation, NSS DB manipulation, openssl invocation for certs.
  Individually trivial, collectively where the time goes.

## Non-goals

- Changing any asset, project type, or tool.
- Changing the state file formats or the DNS/addressing model.
- Building the web UI (separate project; this only clears its path).
