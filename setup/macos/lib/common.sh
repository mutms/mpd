#!/bin/bash
# common.sh — shared constants and helpers for the macos platform.
# Source from every lib/*.sh script:
#   . "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"
#
# Each setup/ platform directory must stay self-contained per AGENTS.md,
# so any cross-platform helpers (CA generation, sudo-recipe printer)
# live here as duplicates rather than sourced shared files.

# --- Constants ---

MPD_REPO="https://github.com/mutms/mpd.git"
VM_NAME_PREFIX="mpd-"
TEMPLATE_NAME="mpd-template"

BRIDGE_SUBNET="10.211.55"                 # Parallels Shared network (default)
BRIDGE_GATEWAY="${BRIDGE_SUBNET}.1"
# Parallels Shared DHCP must be pinned to ${BRIDGE_SUBNET}.1–.99 by the
# template builder (see README). mpd VMs pick a static IP from .100+ so
# they never collide with DHCP-assigned guests.
MIN_STATIC_OCTET=100
MAX_STATIC_OCTET=254

CONTAINER_SUBNET_PREFIX="10.163.0.0/24"
CONTAINER_PROBE_IP="10.163.0.3"           # any IP in the subnet — used for `route get`
DNSMASQ_IP="10.163.0.3"
DNS_DOMAIN="mpd.test"

CA_SUBJECT_MATCH="mpd.test local development CA"
SYSTEM_KEYCHAIN="/Library/Keychains/System.keychain"

STATE_DIR="${HOME}/.mpd-virt"
STATE_CA_FILE="${STATE_DIR}/ca.sha1"
SSH_CONFIG="${HOME}/.ssh/config"
DESKTOP_SHORTCUT="${HOME}/Desktop/mpd-vm.command"

# Parallels Desktop Pro ships prlctl in /usr/local/bin/. Symlinked
# automatically by the Parallels installer; no PATH dance needed.
PRLCTL="/usr/local/bin/prlctl"

# --- Output helpers ---

step() { printf '\n==> %s\n' "$*"; }
ok()   { printf '    ok: %s\n' "$*"; }
warn() { printf '    warn: %s\n' "$*"; }
die()  { printf 'Error: %s\n' "$*" >&2; exit 1; }

# --- VM identity model ---
#
# mpd tracks VMs by their stable Parallels UUID, not by name. The user
# is free to rename a VM in the Parallels GUI; mpd will keep tracking it
# under the same UUID, and the picker will show the current friendly
# name resolved from `prlctl list <uuid>`.
#
# Per-VM state lives at ${STATE_DIR}/<uuid>.env (braces stripped from
# UUID for filename hygiene). The pointer to the currently-active VM
# lives at ${STATE_DIR}/current.env with `MPD_VM_UUID=...`.
#
# `prlctl` accepts both UUID-with-braces and UUID-without-braces, plus
# the friendly name. We always pass the bare UUID when scripted, so a
# concurrent rename in Parallels can't trip us up.

# Strip braces from a Parallels UUID. Idempotent.
uuid_strip() {
    printf '%s' "$1" | tr -d '{}'
}

# --- VM discovery (Parallels) ---

# Echoes "<uuid>\t<name>\t<status>" per line for every mpd-tracked VM
# (one env file per UUID under $STATE_DIR). Resolves the current name +
# state from prlctl at call time; prunes env files for VMs that no
# longer exist in Parallels.
get_mpd_vms() {
    [ -x "$PRLCTL" ] || return 0
    [ -d "$STATE_DIR" ] || return 0
    local envfile base uuid line name state
    for envfile in "$STATE_DIR"/*.env; do
        [ -f "$envfile" ] || continue
        base=$(basename "$envfile")
        # Skip current.env — pointer file, not a tracked VM.
        [ "$base" = "current.env" ] && continue
        uuid=$(awk -F= '/^MPD_VM_UUID=/ { sub(/^MPD_VM_UUID=/, ""); print; exit }' "$envfile")
        [ -z "$uuid" ] && continue
        # `prlctl list <uuid> -o name,status --no-header` returns
        # "<name> <status>" on one line, non-zero exit if missing.
        if ! line=$("$PRLCTL" list "$uuid" -o name,status --no-header 2>/dev/null); then
            # VM is gone from Parallels — drop the stale env file.
            rm -f "$envfile"
            continue
        fi
        name=$(awk '{ print $1 }' <<<"$line")
        state=$(awk '{ print $NF }' <<<"$line")
        printf '%s\t%s\t%s\n' "$uuid" "$name" "$state"
    done | sort -t$'\t' -k 2
}

# Returns the runtime state ("running" / "stopped" / "suspended" /
# "paused" / "missing"). Accepts UUID or name (prlctl handles both).
get_vm_state() {
    local id="$1"
    [ -x "$PRLCTL" ] || { echo "missing"; return; }
    local out
    out=$("$PRLCTL" status "$id" 2>/dev/null) || { echo "missing"; return; }
    awk '{ print $NF }' <<<"$out"
}

vm_exists() {
    local id="$1"
    [ -x "$PRLCTL" ] && "$PRLCTL" status "$id" >/dev/null 2>&1
}

# Resolve a VM's current friendly Parallels name from its UUID. Empty
# on miss. The name *can* drift between setup runs (the user may rename
# in the Parallels GUI); call this at the moment you need the current
# name rather than relying on the snapshot in the env file.
get_vm_name_by_uuid() {
    local uuid="$1"
    [ -x "$PRLCTL" ] || return 0
    "$PRLCTL" list "$uuid" -o name --no-header 2>/dev/null | awk '{ print $1 }'
}

# Read a VM's UUID directly from Parallels (by name or UUID input).
# Strips braces. Empty on miss.
prlctl_uuid_of() {
    local id="$1"
    [ -x "$PRLCTL" ] || return 0
    "$PRLCTL" list "$id" -o uuid --no-header 2>/dev/null \
        | awk '{ print $1 }' | tr -d '{}'
}

# Poll prlctl for the VM's current guest IP. Parallels Tools reports it
# back over the guest channel; takes 10–30s after boot. Returns 0 + the
# IP on stdout, 1 on timeout. Only matches IPs inside ${BRIDGE_SUBNET}.
# (Parallels also reports loopback addresses; we filter those out.)
get_vm_ip() {
    local name="$1" timeout="${2:-90}" elapsed=0
    while [ $elapsed -lt $timeout ]; do
        local raw ip
        raw=$("$PRLCTL" list "$name" -o ip --no-header 2>/dev/null) || raw=""
        # The IP column may contain comma-separated addresses or "-" when
        # Parallels Tools hasn't reported yet. Pick the first match on our
        # bridge subnet.
        ip=$(awk -v sub="$BRIDGE_SUBNET" '
            { gsub(/,/, " "); for (i = 1; i <= NF; i++) if ($i ~ "^" sub "\\.") { print $i; exit } }
        ' <<<"$raw")
        if [[ "$ip" =~ ^${BRIDGE_SUBNET//./\\.}\.[0-9]+$ ]]; then
            echo "$ip"; return 0
        fi
        sleep 2; elapsed=$((elapsed + 2))
    done
    return 1
}

# Returns 0 if the Parallels template exists and is marked as template.
template_exists() {
    [ -x "$PRLCTL" ] || return 1
    "$PRLCTL" list -t -o name --no-header 2>/dev/null \
        | awk '{ print $1 }' \
        | grep -qx "$TEMPLATE_NAME"
}

# Octet portion of "<prefix><N>" — e.g. "mpd-158" → "158". Empty on no match.
# Always returns exit 0 so callers under `set -e` (e.g. octet=$(extract_octet …))
# don't crash when the VM name has a non-numeric suffix.
extract_octet() {
    local name="$1"
    local prefix_len=${#VM_NAME_PREFIX}
    local rest="${name:prefix_len}"
    if [[ "$rest" =~ ^[0-9]+$ ]]; then
        echo "$rest"
    fi
    return 0
}

# --- Active VM detection ---

# Echo the IP of the VM the persistent route currently points at, or empty.
# We use this as a backstop when current.env is missing/stale: route → IP
# → env file lookup → UUID.
get_current_vm_route_ip() {
    local out dest gw
    out=$(route -n get -inet "$CONTAINER_PROBE_IP" 2>/dev/null) || return 0
    dest=$(awk '/destination:/ { print $2; exit }' <<<"$out")
    gw=$(awk '/gateway:/    { print $2; exit }' <<<"$out")
    [[ "$dest" == 10.163.0* ]] || return 0
    [[ "$gw" =~ ^${BRIDGE_SUBNET//./\\.}\.[0-9]+$ ]] || return 0
    echo "$gw"
}

# Echo the UUID of the env file whose MPD_VM_IP matches the given IP.
# Empty on miss.
get_uuid_by_ip() {
    local target_ip="$1" envfile base ip uuid
    [ -d "$STATE_DIR" ] || return 0
    for envfile in "$STATE_DIR"/*.env; do
        [ -f "$envfile" ] || continue
        base=$(basename "$envfile")
        [ "$base" = "current.env" ] && continue
        ip=$(awk -F= '/^MPD_VM_IP=/ { sub(/^MPD_VM_IP=/, ""); print; exit }' "$envfile")
        if [ "$ip" = "$target_ip" ]; then
            uuid=$(awk -F= '/^MPD_VM_UUID=/ { sub(/^MPD_VM_UUID=/, ""); print; exit }' "$envfile")
            [ -n "$uuid" ] && { echo "$uuid"; return 0; }
        fi
    done
    return 0
}

# Echo the UUID of the currently-active VM, or empty. Primary source:
# current.env. Fallback: route → IP → env file lookup. The fallback lets
# us recover after the user blew away ~/.mpd-virt/current.env but
# kept the per-VM env files (and the host route still points somewhere).
get_current_vm_uuid() {
    local uuid
    uuid=$(read_current_env_field "MPD_VM_UUID")
    if [ -n "$uuid" ]; then
        echo "$uuid"
        return 0
    fi
    local ip
    ip=$(get_current_vm_route_ip)
    if [ -n "$ip" ]; then
        get_uuid_by_ip "$ip"
    fi
    # Always return 0: "no current VM" is a normal state on a fresh host,
    # not an error. Returning the && chain's exit code would make
    # `current_uuid=$(get_current_vm_uuid)` fatal under `set -e`.
    return 0
}

# Read MPD_VM_USER from a UUID's env file; fallback to the host login.
get_vm_ssh_user_by_uuid() {
    local uuid="$1"
    local envfile="${STATE_DIR}/${uuid}.env"
    if [ -f "$envfile" ]; then
        local v
        v=$(awk -F= '/^MPD_VM_USER=/ { sub(/^MPD_VM_USER=/, ""); print; exit }' "$envfile")
        [ -n "$v" ] && { echo "$v"; return; }
    fi
    whoami | tr '[:upper:]' '[:lower:]' | tr -cd 'a-z0-9-'
}

# Read MPD_VM_IP from a UUID's env file.
get_vm_ip_by_uuid() {
    local uuid="$1"
    local envfile="${STATE_DIR}/${uuid}.env"
    [ -f "$envfile" ] || return 0
    awk -F= '/^MPD_VM_IP=/ { sub(/^MPD_VM_IP=/, ""); print; exit }' "$envfile"
}

# --- known_hosts cleanup ---

# Strip stale host keys for any address that mpd reuses across VM rebuilds.
# All mpd targets sit on fixed IPs/names, so a fresh VM means cached keys
# from the previous one would otherwise fail with "REMOTE HOST IDENTIFICATION
# HAS CHANGED" the first time you ssh in.
clear_known_hosts() {
    local known="${HOME}/.ssh/known_hosts"
    [ -f "$known" ] || return 0
    local tmp
    tmp=$(mktemp)
    awk '
        $0 ~ /^10\.163\.0\./       { next }
        $0 ~ /\.mpd\.test/         { next }
        $0 ~ /^10\.211\.55\./      { next }
        $0 ~ /^mpd-/       { next }
        { print }
    ' "$known" > "$tmp" && mv "$tmp" "$known"
    chmod 600 "$known" 2>/dev/null || true
}

# --- SSH helpers ---

ssh_cmd() {
    local host="$1" user="$2"
    shift 2
    ssh -o StrictHostKeyChecking=no -o BatchMode=yes "${user}@${host}" "$@"
}

# Wait for SSH to come up at host:port. Returns 0 on success, 1 on timeout.
wait_for_ssh() {
    local host="$1" user="$2" timeout="${3:-300}"
    local elapsed=0
    while [ $elapsed -lt $timeout ]; do
        if ssh -o ConnectTimeout=2 -o StrictHostKeyChecking=no -o BatchMode=yes \
               "${user}@${host}" true 2>/dev/null; then
            return 0
        fi
        sleep 5
        elapsed=$((elapsed + 5))
        if [ $((elapsed % 30)) -eq 0 ]; then
            echo "    Still waiting... (${elapsed}s / ${timeout}s)"
        fi
    done
    return 1
}

# --- Parallels VM control ---

# `prlctl start` is idempotent on running VMs (no-op + 0 exit). For a
# suspended VM it resumes; for stopped it cold-starts.
vm_start() {
    "$PRLCTL" start "$1"
}

# Suspend = freeze RAM to disk, fast resume on next start (Parallels'
# default for `Cmd+P` in the GUI). Matches macos's vm_suspend
# semantics.
vm_suspend() {
    "$PRLCTL" suspend "$1"
}

# Hard stop (--kill). For graceful ACPI shutdown use `prlctl stop`
# without --kill; mpd's lifecycle hooks (~/.config/systemd/user/mpd.service)
# already drained things by the time we reach here, so killing is fine.
vm_force_stop() {
    "$PRLCTL" stop "$1" --kill 2>/dev/null || "$PRLCTL" stop "$1"
}

# Delete: unregister + remove from disk. Prompts in the Parallels GUI by
# default; --force skips that.
vm_delete() {
    "$PRLCTL" delete "$1"
}

# --- ~/.ssh/config block ---
# Managed with explicit start/end markers so re-runs are idempotent.

# Platform-agnostic markers. macos and macos share the same
# block so switching between them (or having both installed in the
# past) just replaces the previous platform's entries cleanly.
SSH_BLOCK_START="# >>> mpd-vm >>>"
SSH_BLOCK_END="# <<< mpd-vm <<<"

set_mpd_ssh_config() {
    local vm_name="$1" vm_ip="$2" vm_user="$3"
    local dir="${HOME}/.ssh"
    mkdir -p "$dir"
    chmod 700 "$dir"
    : >> "$SSH_CONFIG"

    local tmp
    tmp=$(mktemp)
    awk -v s="$SSH_BLOCK_START" -v e="$SSH_BLOCK_END" '
        $0 == s { in_block = 1; next }
        in_block && $0 == e { in_block = 0; next }
        !in_block { print }
    ' "$SSH_CONFIG" > "$tmp"

    # Trim trailing blank lines from the kept content.
    awk '
        /^$/ { blanks = blanks $0 "\n"; next }
        { printf "%s%s\n", blanks, $0; blanks = "" }
    ' "$tmp" > "${tmp}.x"
    mv "${tmp}.x" "$tmp"

    {
        cat "$tmp"
        [ -s "$tmp" ] && echo
        echo "$SSH_BLOCK_START"
        echo "Host $vm_name"
        echo "    HostName $vm_ip"
        echo "    User $vm_user"
        echo "    StrictHostKeyChecking no"
        echo "$SSH_BLOCK_END"
    } > "$SSH_CONFIG"

    rm -f "$tmp"
    chmod 600 "$SSH_CONFIG"
    ok "SSH config: 'ssh $vm_name' -> $vm_ip ($vm_user)"
}

remove_mpd_ssh_config() {
    [ -f "$SSH_CONFIG" ] || return 0
    local tmp
    tmp=$(mktemp)
    awk -v s="$SSH_BLOCK_START" -v e="$SSH_BLOCK_END" '
        $0 == s { in_block = 1; next }
        in_block && $0 == e { in_block = 0; next }
        !in_block { print }
    ' "$SSH_CONFIG" > "$tmp"
    mv "$tmp" "$SSH_CONFIG"
    chmod 600 "$SSH_CONFIG"
}

# --- ~/.mpd-virt/ state files ---

write_mpd_current_env() {
    local vm_uuid="$1" vm_name="$2" vm_ip="$3" vm_user="$4"
    mkdir -p "$STATE_DIR"
    local content
    content=$(printf 'MPD_VM_UUID=%s\nMPD_VM_NAME=%s\nMPD_VM_IP=%s\nMPD_VM_USER=%s\n' \
                     "$vm_uuid" "$vm_name" "$vm_ip" "$vm_user")
    printf '%s' "$content" > "${STATE_DIR}/${vm_uuid}.env"
    printf '%s' "$content" > "${STATE_DIR}/current.env"
    ok "current.env updated ($vm_name [${vm_uuid}] at $vm_ip)"
}

read_current_env_field() {
    local key="$1" file="${STATE_DIR}/current.env"
    [ -f "$file" ] || return 0
    awk -F= -v k="$key" '$1 == k { sub("^"k"=", ""); print; exit }' "$file"
}

# --- Desktop shortcut ---
# Always (re)write so behavior fixes here roll out without forcing users
# to delete the icon by hand. The file is auto-generated and not meant to
# be edited.

ensure_desktop_shortcut() {
    cat > "$DESKTOP_SHORTCUT" <<'EOF'
#!/bin/bash
# Auto-generated by setup/macos/lib/setup.sh.
# Opens an SSH session to the currently-active mpd VM. The VM's name is
# read from ~/.mpd-virt/current.env at click time, so this single
# shortcut tracks whichever VM `setup.command` last activated. VM
# start/suspend is owned by Parallels Desktop — if the VM is offline,
# this shortcut tells you to start it there.

CURRENT_ENV="$HOME/.mpd-virt/current.env"

VM_NAME=""
if [ -r "$CURRENT_ENV" ]; then
    VM_NAME=$(awk -F= '/^MPD_VM_NAME=/ { sub(/^MPD_VM_NAME=/, ""); print; exit }' "$CURRENT_ENV")
fi
if [ -z "$VM_NAME" ]; then
    echo
    echo "  No active mpd VM recorded at ${CURRENT_ENV}."
    echo "  Run setup.command in setup/macos/ first."
    exit 1
fi

if ! ssh -o ConnectTimeout=3 -o BatchMode=yes -o StrictHostKeyChecking=no \
        "$VM_NAME" true 2>/dev/null; then
    echo
    echo "  ${VM_NAME} is not reachable."
    echo "  Start it in Parallels Desktop (Cmd+R or the toolbar), then"
    echo "  double-click this shortcut again. If the route went stale,"
    echo "  run doctor.command from setup/macos/ ."
    exit 1
fi

ssh "$VM_NAME"
status=$?
if [ "$status" -eq 255 ]; then
    echo
    echo "  Could not connect to ${VM_NAME}."
    echo "  Open Parallels Desktop and check the VM is running, or run"
    echo "  doctor.command from setup/macos/ ."
    exit 1
fi
EOF
    chmod +x "$DESKTOP_SHORTCUT"
}

# --- CA generation (host-side) ---
# generate_mpd_ca is the bash twin of Mpd.Environment.Certificate.generateCA
# in mpd/Environment/Certificate.swift. Both must produce certs with the
# same DN, v3_ca extensions, and name constraints so mpd inside the VM
# can reuse a host-generated CA. KEEP IN SYNC with the macos twin.

generate_mpd_ca() {
    local key_path="$1" cert_path="$2"
    local conf
    conf=$(mktemp -t mpd-ca-conf)
    cat > "$conf" <<'EOF'
[ req ]
distinguished_name = req_dn
x509_extensions    = v3_ca
prompt             = no

[ req_dn ]
O  = mpd.test local development CA
CN = mpd.test local development CA

[ v3_ca ]
basicConstraints       = critical, CA:TRUE, pathlen:0
subjectKeyIdentifier   = hash
keyUsage               = critical, keyCertSign, cRLSign
nameConstraints        = critical, @name_constraints

[ name_constraints ]
permitted;DNS.0        = .mpd.test
permitted;DNS.1        = mpd.test
EOF
    openssl genrsa -out "$key_path" 4096 >/dev/null 2>&1 \
        || { rm -f "$conf"; die "openssl genrsa failed"; }
    openssl req -new -x509 -key "$key_path" -out "$cert_path" -days 3650 -config "$conf" >/dev/null 2>&1 \
        || { rm -f "$conf"; die "openssl req failed"; }
    rm -f "$conf"
    chmod 600 "$key_path"
    chmod 644 "$cert_path"
}

# --- Host CA preparation ---
# See setup/macos/lib/common.sh:prepare_host_ca for the rationale.
# This is a verbatim copy modulo wording; both platforms share the same
# caroot canonical + ~/.mpd-virt/ca/ mirror layout.

HOST_CA_PEM=""
HOST_CA_KEY=""

copy_ca_files() {
    local src_pem="$1" src_key="$2" dest_dir="$3"
    mkdir -p "$dest_dir"
    chmod 700 "$dest_dir"
    cp "$src_pem" "${dest_dir}/rootCA.pem"
    cp "$src_key" "${dest_dir}/rootCA-key.pem"
    chmod 644 "${dest_dir}/rootCA.pem"
    chmod 600 "${dest_dir}/rootCA-key.pem"
}

# prepare_host_ca — locate or generate the local CA on the macOS host.
#
# Source of truth: ${HOME}/.mpd-virt/conf/caroot/ ("caroot"). This is
# the path mpd-desktop and the in-VM mpd both reference. Whatever lands
# here is what ships into every runtime container and into the host
# keychain. On uninstall, this directory's continued existence is what
# protects the keychain trust from being torn down.
#
# Disposable mirror: ${STATE_DIR}/ca/ (~/.mpd-virt/ca/). Survives a
# corrupted/blown-away repo checkout so the user can re-clone without
# regenerating a CA. Deleted on uninstall.
prepare_host_ca() {
    local mpd_conf="${HOME}/.mpd-virt/conf"
    local caroot="${mpd_conf}/caroot"
    local caroot_pem="${caroot}/rootCA.pem"
    local caroot_key="${caroot}/rootCA-key.pem"

    local platform_caroot="${STATE_DIR}/ca"
    local platform_pem="${platform_caroot}/rootCA.pem"
    local platform_key="${platform_caroot}/rootCA-key.pem"

    local caroot_present=0 platform_present=0
    [ -f "$caroot_pem" ] && [ -f "$caroot_key" ]   && caroot_present=1
    [ -f "$platform_pem" ] && [ -f "$platform_key" ] && platform_present=1

    if [ "$caroot_present" = 1 ] && [ "$platform_present" = 1 ]; then
        if cmp -s "$caroot_pem" "$platform_pem"; then
            HOST_CA_PEM="$caroot_pem"
            HOST_CA_KEY="$caroot_key"
            ok "reusing host CA at ${caroot} (also mirrored at ${platform_caroot})"
            return 0
        fi
        warn "CA differs between ${caroot} and ${platform_caroot} — using caroot/, replacing platform copy"
        copy_ca_files "$caroot_pem" "$caroot_key" "$platform_caroot"
        HOST_CA_PEM="$caroot_pem"
        HOST_CA_KEY="$caroot_key"
        return 0
    fi

    if [ "$caroot_present" = 1 ]; then
        copy_ca_files "$caroot_pem" "$caroot_key" "$platform_caroot"
        HOST_CA_PEM="$caroot_pem"
        HOST_CA_KEY="$caroot_key"
        ok "reusing host CA at ${caroot} (mirrored to ${platform_caroot})"
        return 0
    fi

    if [ "$platform_present" = 1 ]; then
        if [ -d "$mpd_conf" ]; then
            copy_ca_files "$platform_pem" "$platform_key" "$caroot"
            HOST_CA_PEM="$caroot_pem"
            HOST_CA_KEY="$caroot_key"
            ok "reusing host CA at ${platform_caroot} (mirrored to ${caroot})"
        else
            HOST_CA_PEM="$platform_pem"
            HOST_CA_KEY="$platform_key"
            ok "reusing host CA at ${platform_caroot}"
        fi
        return 0
    fi

    # Neither location has the CA — generate fresh.
    if [ -d "$mpd_conf" ]; then
        mkdir -p "$caroot"
        chmod 700 "$caroot"
        generate_mpd_ca "$caroot_key" "$caroot_pem"
        copy_ca_files "$caroot_pem" "$caroot_key" "$platform_caroot"
        HOST_CA_PEM="$caroot_pem"
        HOST_CA_KEY="$caroot_key"
        ok "generated host CA at ${caroot} (mirrored to ${platform_caroot})"
        return 0
    fi

    mkdir -p "$platform_caroot"
    chmod 700 "$platform_caroot"
    generate_mpd_ca "$platform_key" "$platform_pem"
    HOST_CA_PEM="$platform_pem"
    HOST_CA_KEY="$platform_key"
    ok "generated host CA at ${platform_caroot}"
}

# --- Idempotent host-side privileged ops ---
# Route is *not* persisted across host reboots — `doctor.command`
# re-asserts it (one sudo prompt). Macs reboot rarely; the upside of
# avoiding a LaunchDaemon is a sudo recipe that is two lines of
# `route` instead of an opaque launchctl + plist dance.

route_needs_update() {
    local target_ip="$1"
    local out dest gw
    out=$(route -n get -inet "$CONTAINER_PROBE_IP" 2>/dev/null || true)
    dest=$(awk '/destination:/ { print $2; exit }' <<<"$out")
    gw=$(awk '/gateway:/    { print $2; exit }' <<<"$out")
    if [[ "$dest" == 10.163.0* ]] && [ "$gw" = "$target_ip" ]; then
        return 1
    fi
    return 0
}

apply_route() {
    local target_ip="$1"
    local out dest gw
    out=$(route -n get -inet "$CONTAINER_PROBE_IP" 2>/dev/null || true)
    dest=$(awk '/destination:/ { print $2; exit }' <<<"$out")
    gw=$(awk '/gateway:/    { print $2; exit }' <<<"$out")
    if [[ "$dest" == 10.163.0* ]] && [ -n "$gw" ]; then
        sudo route -n delete -net "$CONTAINER_SUBNET_PREFIX" >/dev/null 2>&1 || true
    fi
    sudo route -n add -net "$CONTAINER_SUBNET_PREFIX" "$target_ip" >/dev/null
}

resolver_needs_update() {
    local desired="nameserver ${DNSMASQ_IP}"
    local path="/etc/resolver/${DNS_DOMAIN}"
    [ -f "$path" ] && [ "$(cat "$path" 2>/dev/null)" = "$desired" ] && return 1
    return 0
}

apply_resolver() {
    local desired="nameserver ${DNSMASQ_IP}"
    local path="/etc/resolver/${DNS_DOMAIN}"
    sudo mkdir -p /etc/resolver
    printf '%s\n' "$desired" | sudo tee "$path" >/dev/null
    sudo chmod 0644 "$path"
}

ca_fingerprint() {
    local cert_path="$1"
    openssl x509 -fingerprint -sha1 -noout -in "$cert_path" 2>/dev/null \
        | awk -F= '{ print $2 }' | tr -d ':' | tr 'a-f' 'A-F'
}

ca_in_keychain() {
    local cert_path="$1"
    local fp
    fp=$(ca_fingerprint "$cert_path")
    [ -n "$fp" ] || return 1
    security find-certificate -a -Z "$SYSTEM_KEYCHAIN" 2>/dev/null \
        | grep -q "^SHA-1 hash: ${fp}$"
}

apply_ca_from_file() {
    local cert_path="$1"
    sudo security add-trusted-cert -d -r trustRoot -k "$SYSTEM_KEYCHAIN" "$cert_path"
    record_ca_fingerprint "$cert_path"
}

record_ca_fingerprint() {
    local cert_path="$1"
    local fp
    fp=$(ca_fingerprint "$cert_path")
    if [ -n "$fp" ]; then
        mkdir -p "$STATE_DIR"
        printf '%s\n' "$fp" > "$STATE_CA_FILE"
    fi
}

print_sudo_recipe() {
    echo
    echo "    The following commands need to run as root:"
    echo
    for cmd in "$@"; do
        printf '        %s\n' "$cmd"
    done
    printf '        %s\n' "sudo -k"
    echo
    echo "    (The trailing 'sudo -k' invalidates your cached sudo credential"
    echo "    after the recipe completes — same fence the script applies on"
    echo "    its own privileged block.)"
    echo
    echo "    You can:"
    echo "      (a) Run them yourself in another terminal, then press Enter here."
    echo "      (b) Press Enter to let this script run them (it will prompt"
    echo "          for your password once)."
    echo
    read -r -p "    Press Enter to continue: " _
}
