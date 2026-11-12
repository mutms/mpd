#!/bin/bash
# chromedriver.sh — the WebDriver endpoints Behat talks to. Sourced by the
# behat tool.
#
# Behat drives Debian's own Chromium through chromedriver. There are two
# endpoints, one per Behat profile in
# config-mpd.php. The ports below must match the ones in that file.
#
#   default  port 9515  headless. One chromedriver for the whole VM, started
#                       by the first run that needs it and left running. It
#                       serves every project and every behat site at once.
#   headed   port 9516  a visible browser on the desktop, for debugging.
#                       Started for one run and stopped when the run ends.
#
# chromedriver listens on localhost only, which is where Behat runs.

MPD_CHROMEDRIVER_PORT=9515
MPD_CHROMEDRIVER_HEADED_PORT=9516
# /var/lib/mpd belongs to the developer, so no sudo is involved.
MPD_CHROMEDRIVER_DIR=/var/lib/mpd/chromedriver

# _chromedriver_listening <port> — succeeds when a driver answers there.
_chromedriver_listening() {
    curl -fsS -m 2 -o /dev/null "http://127.0.0.1:${1}/status" 2>/dev/null
}

# _chromedriver_pid <port> — prints the pid of this user's driver on a port.
_chromedriver_pid() {
    # -x matches the process name, so a shell whose command line merely
    # mentions chromedriver is not mistaken for one.
    # pgrep exits 1 when nothing matches, which must not end a caller that
    # runs under `set -eo pipefail`.
    pgrep -u "$(id -u)" -x chromedriver -a | awk -v arg="--port=${1}" '$3 == arg { print $1; exit }' || true
}

# _chromedriver_wait <port> — waits up to ten seconds for a driver to answer.
_chromedriver_wait() {
    local i
    for i in $(seq 1 50); do
        _chromedriver_listening "$1" && return 0
        sleep 0.2
    done
    return 1
}

# _chromedriver_require — fails when the packages are missing.
_chromedriver_require() {
    if ! command -v chromedriver >/dev/null 2>&1 || ! command -v chromium >/dev/null 2>&1; then
        echo "Error: Chromium or chromedriver is not installed." >&2
        return 1
    fi
}

# chromedriver_ensure_headless — makes sure the shared headless driver
# answers on MPD_CHROMEDRIVER_PORT, starting it when it does not.
#
# A driver whose binary was replaced by a package update is restarted when
# it is idle: an old driver refuses a newer Chromium. One that still serves
# a run is left alone, because stopping it would kill that run.
chromedriver_ensure_headless() {
    local port="$MPD_CHROMEDRIVER_PORT" pid
    _chromedriver_require || return 1
    mkdir -p "$MPD_CHROMEDRIVER_DIR"

    # Two runs starting together must not both launch a driver.
    exec 9>"${MPD_CHROMEDRIVER_DIR}/headless.lock"
    flock 9

    pid=$(_chromedriver_pid "$port")
    if [ -n "$pid" ] && [[ "$(readlink "/proc/${pid}/exe" 2>/dev/null)" == *"(deleted)" ]]; then
        if pgrep -P "$pid" >/dev/null 2>&1; then
            echo "Warning: chromedriver was updated but the old one (pid ${pid}) still serves a run." >&2
            echo "If this run fails to start a browser, wait for the other run, then: kill ${pid}" >&2
        else
            kill "$pid" 2>/dev/null || true
            while kill -0 "$pid" 2>/dev/null; do sleep 0.1; done
        fi
    fi

    if ! _chromedriver_listening "$port"; then
        # No display on purpose: a headed request to this driver fails
        # instead of opening a window on someone's desktop. setsid detaches
        # it from this terminal, so it outlives the run that started it.
        env -u DISPLAY -u WAYLAND_DISPLAY \
            setsid nohup chromedriver --port="$port" \
            >>"${MPD_CHROMEDRIVER_DIR}/headless.log" 2>&1 </dev/null 9>&- &
        if ! _chromedriver_wait "$port"; then
            echo "Error: chromedriver did not start on port ${port}." >&2
            echo "See ${MPD_CHROMEDRIVER_DIR}/headless.log" >&2
            exec 9>&-
            return 1
        fi
    fi
    exec 9>&-
}

# _chromedriver_find_display — exports the display a headed browser should
# open on. Inside a desktop session the environment already names it. From
# an SSH or IDE terminal, take this user's running desktop: an RDP session
# (`rdp-start`) or the console desktop (`gnome-start`).
_chromedriver_find_display() {
    local sock auth
    if [ -n "${DISPLAY:-}" ] || [ -n "${WAYLAND_DISPLAY:-}" ]; then
        return 0
    fi
    for sock in /tmp/.X11-unix/X*; do
        [ -S "$sock" ] && [ -O "$sock" ] || continue
        export DISPLAY=":${sock##*/X}"
        # The cookie is optional. xrdp's X server often runs without one
        # and then accepts this user's local connections as they are. The
        # console desktop runs Wayland, and its Xwayland keeps the cookie
        # under /run/user.
        for auth in "${HOME}/.Xauthority" "/run/user/$(id -u)"/.mutter-Xwaylandauth.*; do
            [ -r "$auth" ] || continue
            export XAUTHORITY="$auth"
            break
        done
        return 0
    done
    return 1
}

# chromedriver_start_headed — starts a driver with a display on
# MPD_CHROMEDRIVER_HEADED_PORT and sets MPD_CHROMEDRIVER_HEADED_PID, which
# the caller must kill when the run ends. When a driver already answers
# there (another headed run, or one you started by hand), that one is used
# and the pid stays empty.
chromedriver_start_headed() {
    local port="$MPD_CHROMEDRIVER_HEADED_PORT"
    MPD_CHROMEDRIVER_HEADED_PID=""
    _chromedriver_require || return 1

    if _chromedriver_listening "$port"; then
        echo "Using the chromedriver already listening on port ${port}." >&2
        return 0
    fi
    if ! _chromedriver_find_display; then
        echo "Error: --profile=headed needs a desktop to show the browser on, and none is running." >&2
        echo "Start one with 'rdp-start' (remote desktop) or 'gnome-start' (VM console)," >&2
        echo "log in, then run this again." >&2
        return 1
    fi

    mkdir -p "$MPD_CHROMEDRIVER_DIR"
    chromedriver --port="$port" >>"${MPD_CHROMEDRIVER_DIR}/headed.log" 2>&1 </dev/null &
    MPD_CHROMEDRIVER_HEADED_PID=$!
    if ! _chromedriver_wait "$port"; then
        echo "Error: chromedriver did not start on port ${port}." >&2
        echo "See ${MPD_CHROMEDRIVER_DIR}/headed.log" >&2
        kill "$MPD_CHROMEDRIVER_HEADED_PID" 2>/dev/null || true
        MPD_CHROMEDRIVER_HEADED_PID=""
        return 1
    fi
    echo "Browser windows open on display ${WAYLAND_DISPLAY:-${DISPLAY:-?}}." >&2
}
