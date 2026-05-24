#!/bin/bash
# setup.sh — build + run the mpd podman-host POC container, then run
# the in-container bootstrap chain end-to-end.
#
# Idempotent: if the container exists, you'll be prompted to recreate
# it. Re-running otherwise skips the build (podman build is cached
# anyway) and re-runs bootstrap (also idempotent).
#
# Status: experimental — see README.md and
# docs/proposals/podman-host-nested.md.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${SCRIPT_DIR}"

# --- Config ----------------------------------------------------------
IMAGE_NAME="${IMAGE_NAME:-mpd-poc}"
CONTAINER_NAME="${CONTAINER_NAME:-mpd-poc}"
SSH_PORT="${SSH_PORT:-2223}"
OCTET="${OCTET:-000}"                              # sandbox path
DEV_USER="${DEV_USER:-$(whoami)}"
HOSTNAME="mpd-${OCTET}"
PUBKEY="${PUBKEY:-${HOME}/.ssh/id_ed25519.pub}"

# --- Output helpers --------------------------------------------------
step() { printf '\n==> %s\n' "$*"; }
ok()   { printf '    ok: %s\n' "$*"; }
warn() { printf '    warn: %s\n' "$*"; }
die()  { printf 'Error: %s\n' "$*" >&2; exit 1; }

# --- Preflight -------------------------------------------------------
command -v podman >/dev/null 2>&1 \
    || die "podman not on PATH. Install Podman Desktop and retry."
[ -f "${PUBKEY}" ] \
    || die "SSH pubkey not found at ${PUBKEY}. Generate one with: ssh-keygen -t ed25519"

step "Config"
ok "image:     ${IMAGE_NAME}"
ok "container: ${CONTAINER_NAME}"
ok "port:      127.0.0.1:${SSH_PORT} -> 22"
ok "hostname:  ${HOSTNAME} (octet ${OCTET})"
ok "user:      ${DEV_USER}"
ok "pubkey:    ${PUBKEY}"

# --- Existing container ---------------------------------------------
if sudo podman container exists "${CONTAINER_NAME}" 2>/dev/null; then
    warn "container '${CONTAINER_NAME}' already exists."
    printf "    Recreate it (y/N)? "
    read -r answer
    if [[ "${answer}" =~ ^[Yy]$ ]]; then
        sudo podman rm -f "${CONTAINER_NAME}" >/dev/null
        ok "removed old container"
    else
        die "aborting — leave the existing container alone."
    fi
fi

# --- Build -----------------------------------------------------------
step "Building image ${IMAGE_NAME}"
trap 'rm -f "${SCRIPT_DIR}/id_ed25519.pub"' EXIT
cp "${PUBKEY}" "${SCRIPT_DIR}/id_ed25519.pub"
sudo podman build \
    --build-arg "DEV_USER=${DEV_USER}" \
    -t "${IMAGE_NAME}" \
    "${SCRIPT_DIR}"
ok "image built"

# --- Run -------------------------------------------------------------
step "Running container ${CONTAINER_NAME}"
sudo podman run -d \
    --name "${CONTAINER_NAME}" \
    --hostname "${HOSTNAME}" \
    --privileged --systemd=always \
    -p "127.0.0.1:${SSH_PORT}:22" \
    "${IMAGE_NAME}" >/dev/null
ok "container started"

# --- Wait for sshd ---------------------------------------------------
step "Waiting for sshd on 127.0.0.1:${SSH_PORT}"
for _ in $(seq 1 30); do
    if ssh -p "${SSH_PORT}" \
           -o ConnectTimeout=2 \
           -o StrictHostKeyChecking=no \
           -o UserKnownHostsFile=/dev/null \
           -o LogLevel=ERROR \
           "${DEV_USER}@localhost" true 2>/dev/null; then
        ok "sshd ready"
        break
    fi
    sleep 1
done

# --- In-container bootstrap -----------------------------------------
# Run each step over SSH so output streams back live and a failure
# stops the chain. The remote shell inherits a stdin we don't write
# to (BatchMode), so any interactive prompt would hang — bootstrap
# steps under sudo NOPASSWD are non-interactive.
ssh_run() {
    ssh -p "${SSH_PORT}" \
        -o StrictHostKeyChecking=no \
        -o UserKnownHostsFile=/dev/null \
        -o LogLevel=ERROR \
        -o BatchMode=yes \
        "${DEV_USER}@localhost" "$@"
}

step "bootstrap/20-git-clone.sh"
ssh_run "bash <(wget -qO- https://raw.githubusercontent.com/mutms/mpd/main/bootstrap/20-git-clone.sh)"

step "bootstrap/30-networking.sh ${OCTET}"
ssh_run "bash /opt/mpd/bootstrap/30-networking.sh ${OCTET}"

step "bootstrap/40-install-software.sh"
ssh_run "bash /opt/mpd/bootstrap/40-install-software.sh"

step "bootstrap/50-build.sh"
ssh_run "bash /opt/mpd/bootstrap/50-build.sh"

step "mpd --setup"
ssh_run "mpd --setup"

step "Done"
ok  "ssh -p ${SSH_PORT} ${DEV_USER}@localhost"
ok  "podman exec -it ${CONTAINER_NAME} bash         # root shell"
