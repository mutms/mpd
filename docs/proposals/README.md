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

- [`macos-host-state-and-wireguard.md`](macos-host-state-and-wireguard.md) —
  Two intertwined architectural decisions for the macOS host:
  state model (`~/.mpd/conf/` + `~/.mpd-virt/`) and WireGuard-based
  networking that eliminates daily sudo. Anchors `mpd-virt`'s
  networking story.
- [`mpd-virt.md`](mpd-virt.md) — `mpd-virt`, a new host-side Swift
  binary that replaces the bash under `setup/macos/lib/` (and the
  planned-but-not-built bash twins for Linux/KVM and WSL/Hyper-V).
  One binary name across platforms, per-backend code gated by
  `#if os(...)`, build matrix split between the existing macOS
  Makefile and a new `Makefile.linux`. macOS+Parallels is the only
  mandatory backend; KVM and Hyper-V are speculative.
