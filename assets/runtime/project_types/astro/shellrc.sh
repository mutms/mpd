# shellcheck shell=bash
# shellrc.sh — astro project type. Sourced by the runtime's ~/.bashrc.
#
# Vite appends this to server.allowedHosts, so it accepts the Host
# header caddy forwards. The leading dot is a wildcard covering every
# project on every VM. See docs/usage.md (Astro) and docs/debugging.md
# ("Blocked request"). If a future Vite drops the variable, the fix is
# server.allowedHosts in astro.config.mjs.
export __VITE_ADDITIONAL_SERVER_ALLOWED_HOSTS=".mpd.test"
