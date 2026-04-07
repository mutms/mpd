# mpd-machine source tree

This directory contains the source material for future `mpd-machine` setup packages and installers.

It is not a standalone product artifact by itself. Instead, it holds the platform-specific bootstrap scripts and related assets that will later be assembled into distribution packages for the dedicated virtual-machine workflow.

Current contents include:

- `platforms/macos-utm/` — UTM-based macOS host bootstrap flow for creating and preparing a Debian VM
- `platforms/generic-vm/` — generic VM provisioning scripts

Canonical product and workflow documentation lives under [docs/machine/README.md](../docs/machine/README.md).
