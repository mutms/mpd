# `node` runtime

Node.js (via nvm) + DB client tools. Per-project node servers run as
systemd units inside the runtime; the Caddy frontdoor sidecar
reverse-proxies to them via the pod-shared netns.

- **`build.sh`** — installs DB clients + Node (LTS via `node-install`).
  No runtime-level tools beyond what `runtime-base/tools/` provides.
- **`project_types/astro/`** — Astro support: `astro-rebuild`,
  `astro-upgrade`.
