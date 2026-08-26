#!/usr/bin/env bash
# 01-bashrc-include.sh — bring an already-adopted VM and its runtime onto the
# bashrc-include.sh layout (mpd commit 9dec27a).
#
# Existing boxes carry the pre-include ~/.bashrc:
#   - the VM has the old '# mpd PATH' + '# mpd vm.env' lines and the
#     '>>> mpd vm prompt >>>' block mpd --vm-setup used to append;
#   - the runtime has the whole inline .bashrc, frozen into its home at
#     create time.
# Fresh adoptions get the new layout automatically; this migrates an existing
# one without a runtime rebuild.
#
# Run from the mpd-virt host, once per VM. Usage: 01-bashrc-include.sh <NNN>
set -euo pipefail

NNN="${1:?usage: 01-bashrc-include.sh <NNN>}"

echo "==> start ${NNN}"
mpd-virt start "${NNN}"

echo "==> re-adopt ${NNN}  (git-pulls /opt/mpd to the new commit and prepends the new VM include line)"
mpd-virt adopt "${NNN}"

echo "==> VM: drop the old managed ~/.bashrc lines (the new include line, added by adopt, stays)"
ssh "mpd-${NNN}-vm" bash -s <<'REMOTE'
set -euo pipefail
sed -i \
    -e '/# >>> mpd vm prompt/,/# <<< mpd vm prompt <<</d' \
    -e '/# mpd PATH$/d' \
    -e '/# mpd vm.env$/d' \
    "$HOME/.bashrc"
REMOTE

echo "==> runtime: overwrite the frozen ~/.bashrc with the new stub (read from the /opt/mpd mount)"
ssh "mpd-${NNN}" bash -s <<'REMOTE'
set -euo pipefail
cp /opt/mpd/assets/runtime/skel/.bashrc "$HOME/.bashrc"
REMOTE

echo "==> done — open a fresh shell on mpd-${NNN} and mpd-${NNN}-vm to verify"
