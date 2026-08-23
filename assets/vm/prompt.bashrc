# Distinguish the VM from the runtime container that runs on it.
#
# The host-side alias for this machine is `mpd-<NNN>-vm` (mpd-virt writes
# it; the bare `mpd-<NNN>` reaches the runtime instead), while the VM's own
# hostname is `mpd-<NNN>` — so `\h` in Debian's default PS1 would echo a
# name that means the other VM. Rewrite just the `\h` token in the PS1
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

# A key on the prompt when this session carries a forwarded SSH agent, so
# whether `git push` can reach a workstation key is a visible property of
# the shell rather than something to recall from the ssh command line.
#
# No convention exists for showing it; the standard part is the detection.
# sshd exports SSH_AUTH_SOCK only when the client asked for forwarding
# (`ssh -A`, or ForwardAgent in its config) — it is what ssh and git
# themselves look at. SSH_CONNECTION pins this to an SSH session: a
# desktop agent exports SSH_AUTH_SOCK too, and a terminal in the VM's own
# GNOME session is not agent forwarding.
#
# Evaluated once at shell start, like the socket. If the forwarded agent
# goes away mid-session the key stays lit; `ssh-add -l` is the live answer.
if [ -n "${PS1-}" ] && [ -n "${SSH_AUTH_SOCK-}" ] && [ -n "${SSH_CONNECTION-}" ]; then
    case "$PS1" in
        '🔑 '*) ;;
        *) PS1="🔑 $PS1" ;;
    esac
fi
