# Proposals

Designs for work we'd like done but haven't committed to a timeline for.
Each proposal is precise enough that a contributor (human or AI) can
implement it end-to-end without needing to re-derive the design.

Difference from sibling docs:

- **[`ROADMAP.md`](../ROADMAP.md)** — committed near-term work.
- **[`VISION.md`](../VISION.md)** — design principles, "why mpd exists."
- **[`ARCHITECTURE.md`](../ARCHITECTURE.md)** — how the current system fits together.
- **`proposals/`** (this dir) — *future* features with spec-level detail.
  Not yet built. Some may never be.

## Index

- [`host-binary-parallels.md`](host-binary-parallels.md) — `mpd-prl`, a
  macOS Swift binary replacing `setup/macos/`'s bash scripts. Primary
  reference for the host-binary trio; specifies cross-cutting design
  (verb surface, namespace tree, sudo-recipe UX, state-file layout).
- [`host-binary-kvm.md`](host-binary-kvm.md) — `mpd-kvm`, the
  Linux+libvirt twin. Delegates cross-cutting design to the Parallels
  proposal; specs only the libvirt-specific deltas.
- [`host-binary-hyperv.md`](host-binary-hyperv.md) — `mpd-hpv`, the
  Windows+Hyper-V twin. Runs **inside WSL2 Debian** as a Linux
  binary and drives Windows-side Hyper-V via `powershell.exe`
  interop — no native Swift-on-Windows toolchain needed. Most
  speculative of the three (no current users).
