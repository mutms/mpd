#!/bin/bash
# bootstrap.sh — turns a fresh Debian Trixie container into a runtime base.
#
# THE ONE ROOT-CONTEXT SCRIPT. The single bootstrap exception named in
# AGENTS.md §"Mandatory privilege rule": runs as root because the dev
# user does not yet exist when it starts. Called only by Mpd.Runtime
# during runtime creation; nothing else may invoke it.
#
# After this returns, the container is a "runtime base":
#   - common dev tools + openssh-server installed
#   - sshd configured (PermitRootLogin no, pubkey auth)
#   - dev user created with matching UID and passwordless sudo
#   - /etc/mpd/runtime identity, /etc/hosts self-record
#   - /home/<user> defaults (~/.bashrc cd /srv/projects, ~/.local/bin on PATH)
#   - /srv/{projects,data,dbs,tools,personal} laid out with correct ownership
#   - /srv/personal/* symlinked into /home/<user>/
#
# Runtime-specific layers (PHP, Node, …) are added on top by
# assets/runtimes/<rt>/build.sh running as the dev user.
set -euo pipefail

CONTAINER_NAME="$1"
EXTUSER="$2"
EXTUID="$3"

export DEBIAN_FRONTEND=noninteractive

# --- Common developer tools ---
apt-get update -qq
apt-get install -y --no-install-recommends \
    bash-completion bc bzip2 curl dnsutils file findutils git gzip htop \
    iproute2 iputils-ping jq less lftp locales locales-all lsof man-db mc \
    nano net-tools netcat-openbsd openssh-client openssh-server patch procps \
    psmisc rsync screen socat strace sudo tar telnet time tmux tree unzip \
    vim wget whois xz-utils zip

# --- OpenSSH (root login disabled; user login via Mac SSH key) ---
mkdir -p /root/.ssh
chmod 700 /root/.ssh
sed -i 's/^#*PermitRootLogin.*/PermitRootLogin no/' /etc/ssh/sshd_config
sed -i 's/^#*PubkeyAuthentication.*/PubkeyAuthentication yes/' /etc/ssh/sshd_config
systemctl enable ssh
systemctl restart ssh || systemctl start ssh

# --- Internal hostname ---
echo "127.0.0.1  ${CONTAINER_NAME}.runtime.mpd.test" >> /etc/hosts

# --- Runtime identity (read by project scripts) ---
mkdir -p /etc/mpd
echo "${CONTAINER_NAME}" > /etc/mpd/runtime

# --- Dev user (matching UID for correct volume file ownership) ---
if ! id "${EXTUSER}" &>/dev/null; then
    useradd -m -u "${EXTUID}" -s /bin/bash "${EXTUSER}"
fi

# Passwordless sudo for the dev user.
echo "${EXTUSER} ALL=(ALL) NOPASSWD:ALL" > "/etc/sudoers.d/${EXTUSER}"
chmod 440 "/etc/sudoers.d/${EXTUSER}"

# --- SSH key directory for the dev user ---
USER_HOME="/home/${EXTUSER}"
mkdir -p "${USER_HOME}/.ssh"
chmod 700 "${USER_HOME}/.ssh"
chown "${EXTUSER}:${EXTUSER}" "${USER_HOME}/.ssh"

# --- Default working directory for SSH sessions ---
cat >> "${USER_HOME}/.bashrc" <<'EOF'
cd /srv/projects 2>/dev/null || true
EOF

# --- ~/.local/bin on PATH for user-installed CLIs (Claude Code, etc.) ---
# Debian's default ~/.profile only adds it for login shells; .bashrc covers
# SSH command execution and non-login interactive shells.
cat >> "${USER_HOME}/.bashrc" <<'EOF'
[ -d "$HOME/.local/bin" ] && PATH="$HOME/.local/bin:$PATH"
EOF

# --- /srv/personal/ — shared developer state across all runtimes ---
# Flat layout (no <user> subdir): runtimes are single-user.
PERSONAL_DIR="/srv/personal"
mkdir -p "${PERSONAL_DIR}/.ssh"
chown -R "${EXTUSER}:${EXTUSER}" "${PERSONAL_DIR}" 2>/dev/null || true

# known_hosts shared across all runtimes
touch "${PERSONAL_DIR}/.ssh/known_hosts"
chown "${EXTUSER}:${EXTUSER}" "${PERSONAL_DIR}/.ssh/known_hosts"
if [ ! -e "${USER_HOME}/.ssh/known_hosts" ]; then
    ln -sf "${PERSONAL_DIR}/.ssh/known_hosts" "${USER_HOME}/.ssh/known_hosts"
fi

# Per-runtime by design: ~/.bash_history (transient, no value carrying it),
# ~/.local (user-installed CLIs — re-provision on runtime recreate),
# ~/.nvm (Node via nvm — same model).

# mpd-user.env — synced from the host's ~/.mpd/mpd-user.env into
# /srv/personal/mpd-user.env by Mpd.Core.State.syncBindMountFiles().
# Symlink into the user's home so the canonical $HOME/mpd-user.env path
# resolves to the volume copy.
if [ ! -e "${USER_HOME}/mpd-user.env" ]; then
    ln -sf "${PERSONAL_DIR}/mpd-user.env" "${USER_HOME}/mpd-user.env"
fi

chown -h "${EXTUSER}:${EXTUSER}" \
    "${USER_HOME}/.ssh/known_hosts" \
    "${USER_HOME}/mpd-user.env" 2>/dev/null || true

# --- /opt/mpd — dev-user-owned system area ---
# A managed scratch space under /opt for whatever wants to install
# system-wide artifacts owned by the dev user (build tools, third-party
# binaries, etc.). Lives in the container overlay — re-provisioned on
# runtime recreate. /opt itself stays root-owned.
mkdir -p /opt/mpd
chown "${EXTUSER}:${EXTUSER}" /opt/mpd

# --- Shared volume directories ---
# /srv/tools is the dev-user-writable area where phase-2 build.sh
# populates /srv/tools/<rt>/ and /srv/tools/<type>/. chown -R fixes
# any stale subtree ownership left over from previous root-context
# provisioning runs on this data volume.
mkdir -p /srv/projects /srv/data /srv/dbs /srv/tools
chown "${EXTUSER}:${EXTUSER}" /srv/projects /srv/data
chown -R "${EXTUSER}:${EXTUSER}" /srv/tools
chown root:root /srv/dbs
chmod 0755 /srv/dbs

# --- Runtime-base tools shared across all runtimes ---
# Tools that work in any Trixie-based runtime (claude-install, node-install,
# …) live in /mnt/assets/runtime-base/tools/. Symlink them into
# /srv/tools/_base/ and add that directory to PATH for every login shell.
# Sourced before /etc/profile.d/mpd-tools-runtime.sh so runtime tools win
# over base tools if any name collides.
mkdir -p /srv/tools/_base
for SCRIPT in /mnt/assets/runtime-base/tools/*; do
    [ -f "$SCRIPT" ] || continue
    SCRIPT_NAME="$(basename "$SCRIPT")"
    ln -sf "$SCRIPT" "/srv/tools/_base/${SCRIPT_NAME}"
done
echo 'export PATH="/srv/tools/_base:$PATH"' > /etc/profile.d/mpd-tools-base.sh
chmod 0644 /etc/profile.d/mpd-tools-base.sh
