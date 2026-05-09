#!/bin/bash
# common.sh — shared constants and helpers for the macos-utm platform.
# Source from every lib/*.sh script:
#   . "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

# --- Constants ---

MPD_REPO="https://github.com/mutms/mpd.git"
VM_NAME_PREFIX="mpd-machine-"

BRIDGE_SUBNET="192.168.64"                # macOS vmnet shared bridge — fixed by vmnet.framework
BRIDGE_GATEWAY="${BRIDGE_SUBNET}.1"

CONTAINER_SUBNET_PREFIX="10.163.0.0/24"
CONTAINER_PROBE_IP="10.163.0.3"           # any IP in the subnet — used for `route get`
DNSMASQ_IP="10.163.0.3"
DNS_DOMAIN="mpd.test"

CA_SUBJECT_MATCH="mpd.test local development CA"
SYSTEM_KEYCHAIN="/Library/Keychains/System.keychain"

STATE_DIR="${HOME}/.mpd-machine"
STATE_CA_FILE="${STATE_DIR}/ca.sha1"
SSH_CONFIG="${HOME}/.ssh/config"
DESKTOP_SHORTCUT="${HOME}/Desktop/mpd-machine.command"

UTMCTL="/Applications/UTM.app/Contents/MacOS/utmctl"

# Cloud image URL (tar.xz of raw disk — small download, resizable with dd)
CLOUD_BASE="https://cloud.debian.org/images/cloud/trixie/20260501-2465"
CLOUD_ARCHIVE="debian-13-genericcloud-arm64-20260501-2465.tar.xz"

# --- Output helpers ---

step() { printf '\n==> %s\n' "$*"; }
ok()   { printf '    ok: %s\n' "$*"; }
warn() { printf '    warn: %s\n' "$*"; }
die()  { printf 'Error: %s\n' "$*" >&2; exit 1; }

# --- VM discovery (UTM) ---

# Echoes "<name>\t<status>" per line for every VM whose name starts with the prefix.
# `utmctl list` columns: UUID  Status  Name (header line + body, status is single word).
get_mpd_vms() {
    [ -x "$UTMCTL" ] || return 0
    "$UTMCTL" list 2>/dev/null \
        | awk -v prefix="$VM_NAME_PREFIX" '
            NR == 1 { next }
            NF >= 3 {
                name = ""
                for (i = 3; i <= NF; i++) { name = (i == 3 ? $i : name " " $i) }
                if (name ~ ("^" prefix "[0-9]+$")) { printf "%s\t%s\n", name, $2 }
            }
          ' \
        | sort
}

get_vm_state() {
    local name="$1"
    [ -x "$UTMCTL" ] || { echo "missing"; return; }
    "$UTMCTL" status "$name" 2>/dev/null || echo "missing"
}

vm_exists() {
    local name="$1"
    [ -x "$UTMCTL" ] && "$UTMCTL" status "$name" >/dev/null 2>&1
}

# Octet portion of "<prefix><N>" — e.g. "mpd-machine-158" → "158". Empty on no match.
# Always returns exit 0 so callers under `set -e` (e.g. octet=$(extract_octet …))
# don't crash when the VM name has a non-numeric suffix (mpd-machine-sandbox).
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

# Echoes the last octet of the VM the persistent route currently points at, or empty.
get_current_vm_octet() {
    local out dest gw
    out=$(route -n get -inet "$CONTAINER_PROBE_IP" 2>/dev/null) || return 0
    dest=$(awk '/destination:/ { print $2; exit }' <<<"$out")
    gw=$(awk '/gateway:/    { print $2; exit }' <<<"$out")
    # When a 10.163.0.0/24 route exists, destination is "10.163.0/24", "10.163.0",
    # or similar — always begins with "10.163.0". Default route shows "default".
    [[ "$dest" == 10.163.0* ]] || return 0
    if [[ "$gw" =~ ^${BRIDGE_SUBNET//./\\.}\.([0-9]+)$ ]]; then
        echo "${BASH_REMATCH[1]}"
    fi
}

# SSH user for a VM. Lookup order: state file, ssh config, host login fallback.
get_vm_ssh_user() {
    # Split into two `local` statements. macOS ships bash 3.2, which expands
    # all RHS values in a single `local` BEFORE assigning any LHS — so a
    # combined `local a=$1 b=$a` would look up the (still-unbound) `a` and
    # trip `set -u` in our callers (e.g. start.sh).
    local name="$1"
    local envfile="${STATE_DIR}/${name}.env"
    if [ -f "$envfile" ]; then
        local v
        v=$(awk -F= '/^MPD_VM_USER=/ { sub(/^MPD_VM_USER=/, ""); print; exit }' "$envfile")
        [ -n "$v" ] && { echo "$v"; return; }
    fi
    if [ -f "$SSH_CONFIG" ]; then
        local v
        v=$(awk -v target="$name" '
            $1 == "Host" {
                in_block = 0
                for (i = 2; i <= NF; i++) if ($i == target) in_block = 1
                next
            }
            in_block && tolower($1) == "user" { print $2; exit }
        ' "$SSH_CONFIG")
        [ -n "$v" ] && { echo "$v"; return; }
    fi
    whoami | tr '[:upper:]' '[:lower:]' | tr -cd 'a-z0-9-'
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
        $0 ~ /^192\.168\.64\./     { next }
        $0 ~ /^mpd-machine-/       { next }
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

# --- UTM control via AppleScript ---

vm_start() {
    osascript <<APPLESCRIPT
tell application "UTM"
    start (virtual machine named "$1")
end tell
APPLESCRIPT
}

vm_suspend() {
    osascript <<APPLESCRIPT
tell application "UTM"
    suspend (virtual machine named "$1")
end tell
APPLESCRIPT
}

vm_force_stop() {
    osascript <<APPLESCRIPT
tell application "UTM"
    stop (virtual machine named "$1")
end tell
APPLESCRIPT
}

vm_delete() {
    osascript <<APPLESCRIPT
tell application "UTM"
    delete (virtual machine named "$1")
end tell
APPLESCRIPT
}

# --- ~/.ssh/config block ---
# Managed with explicit start/end markers so re-runs are idempotent.

SSH_BLOCK_START="# >>> mpd-machine (managed by macos-utm) >>>"
SSH_BLOCK_END="# <<< mpd-machine <<<"

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
        echo "Host mpd-machine $vm_name"
        echo "    HostName $vm_ip"
        echo "    User $vm_user"
        echo "    StrictHostKeyChecking no"
        echo "$SSH_BLOCK_END"
    } > "$SSH_CONFIG"

    rm -f "$tmp"
    chmod 600 "$SSH_CONFIG"
    ok "SSH config: 'ssh mpd-machine' -> $vm_ip ($vm_user)"
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

# --- ~/.mpd-machine/ state files ---

write_mpd_current_env() {
    local vm_name="$1" vm_ip="$2" vm_user="$3"
    mkdir -p "$STATE_DIR"
    local content
    content=$(printf 'MPD_VM_NAME=%s\nMPD_VM_IP=%s\nMPD_VM_USER=%s\n' \
                     "$vm_name" "$vm_ip" "$vm_user")
    printf '%s' "$content" > "${STATE_DIR}/${vm_name}.env"
    printf '%s' "$content" > "${STATE_DIR}/current.env"
    ok "current.env updated ($vm_name at $vm_ip)"
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
# Auto-generated by setup/macos-utm/lib/setup.sh.
# Opens an SSH session to the active mpd-machine VM via the
# `Host mpd-machine` block in ~/.ssh/config. If the VM is offline,
# starts it first via lib/start.sh so a normie double-click "just works".
#
# Failure paths exit non-zero so Terminal's default "Close the window
# if the shell exited cleanly" keeps the window open with the error
# message visible. No `read -p "Press Enter..."` pauses; users who
# prefer "always close" can set their profile accordingly.

START_SH="$HOME/Developer/mpd/setup/macos-utm/lib/start.sh"

# Fast liveness probe — non-interactive, no host-key prompts, short timeout.
if ! ssh -o ConnectTimeout=3 -o BatchMode=yes -o StrictHostKeyChecking=no \
        mpd-machine true 2>/dev/null; then
    if [ -x "$START_SH" ]; then
        echo "mpd-machine is not reachable — bringing the VM up..."
        echo
        bash "$START_SH" || true
        echo
    else
        echo
        echo "  Could not reach mpd-machine, and lib/start.sh was not found at:"
        echo "    $START_SH"
        echo
        echo "  Run setup.command in setup/macos-utm/ to repair."
        exit 1
    fi
fi

ssh mpd-machine
status=$?
if [ "$status" -eq 255 ]; then
    echo
    echo "  Could not connect to mpd-machine."
    echo "  Open UTM and check that the VM is running, or run"
    echo "  start.command from setup/macos-utm/ ."
    exit 1
fi
EOF
    chmod +x "$DESKTOP_SHORTCUT"
}

# --- CA generation (host-side) ---
# generate_mpd_ca is the bash twin of Mpd.Environment.Certificate.generateCA
# in mpd/Environment/Certificate.swift. Both must produce certs with the
# same DN, v3_ca extensions, and name constraints so mpd inside the VM
# can reuse a host-generated CA (per the reuse check at
# mpd/Environment/Machine/MachineActionSetup.swift:331). KEEP IN SYNC.

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
# Keeps a single host CA alive in two real-file locations and mirrors
# between them on every run. The redundant copy is the safety net: wiping
# one (or the keychain entry) still lets the next setup restore from the
# other side automatically.
#
#   - ~/Developer/mpd/conf/caroot/{rootCA.pem,rootCA-key.pem}
#     Canonical mpd location. Shared with mpd-desktop. Only populated when
#     ~/Developer/mpd/conf/ already exists (we never pre-create the repo
#     path on a Mac that hasn't cloned mpd).
#   - ~/.mpd-machine/ca/{rootCA.pem,rootCA-key.pem}
#     Platform-owned location. Always populated on any Mac that has run
#     setup.command at least once.
#
# Behavior matrix:
#   both present, identical content  → reuse caroot/, no-op.
#   both present, divergent content  → caroot/ wins (canonical), platform
#                                       copy overwritten, with a warn.
#   only caroot/                     → mirror to platform.
#   only platform                    → mirror to caroot/ (if conf/ exists),
#                                       else stay platform-only.
#   neither                          → generate fresh; populate caroot/ if
#                                       conf/ exists, else platform-only.
#
# Sets globals HOST_CA_PEM and HOST_CA_KEY; the path points at caroot/
# whenever caroot/ holds the cert, otherwise at the platform copy. Either
# way, both files at the chosen path are real files (not symlinks) ready
# for `scp` upload to a new VM.

HOST_CA_PEM=""
HOST_CA_KEY=""

# copy_ca_files SRC_PEM SRC_KEY DEST_DIR
# Copies a CA cert+key into DEST_DIR with the right modes. Creates DEST_DIR
# if missing. Used to mirror between caroot/ and the platform's state dir.
copy_ca_files() {
    local src_pem="$1" src_key="$2" dest_dir="$3"
    mkdir -p "$dest_dir"
    chmod 700 "$dest_dir"
    cp "$src_pem" "${dest_dir}/rootCA.pem"
    cp "$src_key" "${dest_dir}/rootCA-key.pem"
    chmod 644 "${dest_dir}/rootCA.pem"
    chmod 600 "${dest_dir}/rootCA-key.pem"
}

prepare_host_ca() {
    local mpd_conf="${HOME}/Developer/mpd/conf"
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
# Predicate `*_needs_update` returns 0 when the operation is needed,
# 1 when current state is already correct. The matching `apply_*`
# performs the privileged action; both detect + apply share the same
# state read so a caller can list what's needed before sudo, then
# apply only those after.

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

# Returns 0 if the cert at <path> is already trusted in the System keychain,
# 1 if not (or if the cert can't be read). Echoes the cert's SHA-1 fingerprint
# (uppercase hex, no separators) on stdout for callers that want to record it.
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

# Always record the trusted CA's SHA-1 in $STATE_CA_FILE so uninstall.sh
# can remove this exact cert later. Safe to call whether the script or
# the dev did the import — only depends on the cert file existing on host.
record_ca_fingerprint() {
    local cert_path="$1"
    local fp
    fp=$(ca_fingerprint "$cert_path")
    if [ -n "$fp" ]; then
        mkdir -p "$STATE_DIR"
        printf '%s\n' "$fp" > "$STATE_CA_FILE"
    fi
}

# print_sudo_recipe — present the privileged commands the script is about
# to run and let the dev choose between running them in another terminal
# (and pressing Enter to continue) or pressing Enter to let the script
# sudo for them. Returns 0 unconditionally; the caller MUST re-run its
# predicate checks afterward to determine what (if anything) still needs
# sudo.
#
# Args: each command as a separate string. The function appends a final
# bare `sudo -k` so the dev's terminal also drops cached creds the moment
# the manual recipe finishes — symmetric with the script's own fence.
# The lines are emitted with NO inline `#` comments so they paste cleanly
# into either bash *or* zsh (zsh's `interactive_comments` is off by default
# on macOS, which would otherwise turn `# invalidate ...` into command
# arguments).
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
    echo "    You can either:"
    echo "      (a) Open another Terminal, run the recipe yourself, and press Enter here."
    echo "      (b) Press Enter and let this script sudo for you (you'll be asked for your password)."
    echo
    read -r -p "    Press Enter to continue: " _
}
