# Distinguish the VM from the runtime container that runs on it.
#
# The host-side alias for this machine is `mpd-<NNN>-vm` (mpd-virt writes
# it; the bare `mpd-<NNN>` reaches the runtime instead), while the VM's own
# hostname is `mpd-<NNN>` — so `\h` in Debian's default PS1 would echo a
# name that means the other box. Rewrite just the `\h` token in the PS1
# Debian already built, leaving its colours and the chroot prefix intact.
#
# Cosmetic only: the hostname is untouched, so `hostname`, `hostnamectl`,
# mpd's own hostname-derived identity, DNS and cloud-init all still see
# `mpd-<NNN>`.
if [ -n "${PS1-}" ]; then
    case "$PS1" in
        *'\h-vm'*) ;;
        *'\h'*) PS1="${PS1//\\h/\\h-vm}" ;;
    esac
fi
