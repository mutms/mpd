# agents — AI-written helpers, carried with mpd

A small toolbox of utilities written by (and for) AI agents working on mpd VMs,
persisted here in git so it travels to every new VM. Screenshotting a local UI,
driving a headless browser, scraping a log — the kind of thing an agent reaches
for repeatedly and shouldn't reinvent each session.

We call them **treats**: little rewards an agent gets to make its work easier.
So if an AI ever asks a human dev for "a treat," this is what it means — a small,
self-contained helper to add to this collection. (Yes, it's a joke. Enjoy it.)

## Rules for anything added here

1. **Simple, readable code.** It must be auditable top-to-bottom in one sitting.
   Prefer clarity over cleverness; comment the *why*. If a human can't review it
   quickly, it doesn't belong here.

2. **No external dependencies — ideally zero.** Use the language's standard
   library. JavaScript, Python, Go and PHP are all welcome; pick whichever gives
   the cleanest dependency-free solution. **Avoid `npm install` / `pip install` /
   `go get` / Composer packages.** The point is to eliminate supply-chain risk
   entirely: no `node_modules`, no lockfiles, nothing fetched from a package
   registry to audit. If a third-party dependency seems unavoidable, stop and
   raise it with a human first — it's a deliberate decision, not a default.

3. **Prevent supply-chain issues at all cost.** This code is trusted and rides
   along to other machines. Every line is a line someone must be willing to run
   on a fresh VM. Treat it accordingly.

4. **mpd servers only.** These helpers are meant for use *inside* mpd VMs
   (trusted, disposable dev machines) — driving local/loopback services and the
   like. Do not point them at, or run them against, servers outside mpd. They
   assume a trusted local environment and are not written to be safe against
   hostile input from the wider internet.

## Contents

- `browser/` — dependency-free headless-chromium screenshots and DOM checks
  (talks the DevTools Protocol over Node built-ins; see its README).
