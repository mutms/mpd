# shellcheck shell=bash
# shellrc.sh — astro project type. Sourced by the runtime's ~/.bashrc.
#
# Lets a plain `npm run dev` / `astro dev` be reachable through the caddy
# frontdoor. caddy terminates TLS at https://<project>.<zone>/ and proxies
# to the dev server on loopback, forwarding the original Host header —
# which Vite's dev server rejects unless the name is in server.allowedHosts
# ("Blocked request. This host is not allowed."). The developer would
# otherwise have to pass `--allowed-hosts` on every run, or edit
# astro.config.mjs in a way that only makes sense inside mpd.
#
# Vite reads this variable and appends it to server.allowedHosts. A leading
# dot is its wildcard: `.mpd.test` covers every project on every VM, so this
# is a constant and needs no per-project or per-zone value. mpd's CA is
# name-constrained to the same domain (net.RootDomain), so the scope here
# matches the scope of what mpd can issue certificates for.
#
# The name is a Vite internal (hence the underscores) meant for exactly this
# — a proxy in front of the dev server. If a future Vite drops it, `astro
# dev` starts answering "Blocked request" and the fix is per-project:
# server.allowedHosts in astro.config.mjs.
export __VITE_ADDITIONAL_SERVER_ALLOWED_HOSTS=".mpd.test"
