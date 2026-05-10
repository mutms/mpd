#!/bin/bash
# build.sh — util runtime has nothing to build on top of the runtime base.
# Phase 1 (assets/runtime-base/bootstrap.sh) sets up everything this runtime
# offers, including the shared base tools. The developer SSHes in and
# installs whatever else they need.
set -euo pipefail

echo "Trixie runtime '$1' build complete (nothing beyond the runtime base)."
