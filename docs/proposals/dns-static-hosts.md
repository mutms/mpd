# DNS: one resolver that reads `/etc/hosts` and forwards the rest

Parked design brainstorm. No work scheduled; delete this file when (a shape
of) it ships.

## Why

`*.mpd.test` keeps failing right after a VM starts: a name that *will* resolve
misses at `t=0`, gets negative-cached across a stack of resolvers, and clears
minutes later. It's ~20 names, half of them fixed, dressed up as a discovery
problem it isn't.

## Step 1 — do not touch podman or the containers

The podman network, the containers' `resolv.conf`, and the bridge resolver's
address stay **exactly as they are**. Containers already send their DNS to
`10.163.<NNN>.1:53`; that does not change. This proposal changes only what
answers on that port.

## Step 2 — a trivial resolver reading `/etc/hosts`

`/etc/hosts` on the mpd VM becomes the **single source of truth** for `.test`.
mpd writes the records there — the fixed names at `--vm-setup`, and the one
runtime-assigned name (a DB host) when it creates that container, where the IP
is already in hand.

The resolver on the VM does exactly three things:

- **reads `/etc/hosts` directly** for its records,
- **forwards everything it doesn't know** to the box's default resolver,
- **listens on `10.163.<NNN>.1:53`**, so mpd-proxy (over the tunnel) and every
  podman container reach it — the same address they use today.

That is `dnsmasq` with just: read `/etc/hosts`, one `server=` upstream, bind
the bridge. Gone: the hosts *directory*, `no-hosts`, the `/etc/resolver` hook,
and any `systemd-resolved` routing of `.test`.

## What this deletes

- The separate `hostsdir` record store — records live in `/etc/hosts`, one
  place.
- The `resolved → dnsmasq` routing on the box and mpd-virt's
  `mpd-resolv-stub.service` (the Apple-container resolv.conf unit) — both
  existed only to route `.test` through a resolver.

## Why it stops failing

The records are in a file that exists before anything boots (fixed names) or
the instant the DB container is created. The resolver just reads that file — it
can't be half-loaded or negative-cache a name whose line is already there. If
the *service* behind a name isn't up you get connection-refused, not a cached
NXDOMAIN that lingers for minutes.

## Caveat to handle

cloud-init rewrites `/etc/hosts` on some images — pin it with a drop-in
`/etc/cloud/cloud.cfg.d/99-mpd.cfg` → `manage_etc_hosts: false`, so nothing
clobbers mpd's records.
