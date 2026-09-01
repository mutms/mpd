# Machine Networking (mpd VM)

How the host laptop reaches mpd's container subnet inside the VM.

The host-side bits (the WireGuard overlay or the SOCKS fallback, split
DNS, CA trust) are configured by the **mpd-virt** orchestrator and its
**mpd-proxy** helper (separate repos) — not by the in-VM `mpd` binary.
This document describes the topology and the host↔VM↔containers data path;
for the actual host commands see `mpd-virt`'s own documentation.

## Topology

```text
Laptop (macOS — primary)      reaches the VM by IP; needs only :22 + :51820
  │
  │  WireGuard overlay (mpd-proxy)          → carries the whole 10.163.<NNN>.0/24
  │  or  SOCKS over SSH (ssh -N mpd-<NNN>-socks) → same reach, via sshd on the VM
  │
VM (Debian Trixie)   hostname mpd-<NNN>;  LAN IP exposes ONLY sshd + wg
  │
  │  Static bridge:  mpdbr0  — two VM addresses (nothing binds the LAN IP)
  │    10.163.<NNN>.1   dnsmasq   :53  — DNS for *.test
  │                     caddy     :443 — the zone apex only (the portal)
  │    10.163.<NNN>.2   mpd-caddy :443 — every project vhost
  │
  `mpd-internal` Podman network    10.163.<NNN>.0/24  (podman DNS disabled)
    │   SEALED from the LAN by an nft firewall (mpd-firewall.service);
    │   only mpdbr0 and wg0 may route in, on both the forward and the
    │   input hook — the VM holds .1 and .2 itself, and those arrive on
    │   input, which the forward chain never sees
    +-- DB containers           10.163.<NNN>.10–.99
    +-- extra service containers 10.163.<NNN>.100–.199  (plain HTTP:
                                 mailpit .100, adminer .102, selenium .103)
```

The bridge is named `mpdbr0` rather than taking podman's
`podman0`/`podman1` counter, whose value depends on what other networks
were created first. dnsmasq names that interface in its config, so a name
that drifts is a name that silently stops resolving.

It is deliberately not `mpd0`: that was the WireGuard tunnel mpd used
before it moved to a routed subnet (removed 2026-07-20), and VMs
bootstrapped before then still bring one up at boot. Reusing the name made
netavark refuse the network outright — *"bridge interface mpd0 already
exists but is a Wireguard interface"*. A VM created before the rename
keeps whatever name its network was made with; mpd reads the interface
back from podman rather than assuming, so both work.

The VM runs `net.ipv4.ip_forward=1` (netavark needs it for the
container→internet masquerade), but an nft firewall
(`mpd-firewall.service`) drops NEW forwarded connections into
`10.163.<NNN>.0/24` from any interface but the bridge itself and `wg0`.
The LAN/public side is sealed; the WireGuard overlay legitimately
carries the whole /24 to the laptop (`mpd-virt` sets the peer's
AllowedIPs to the /24), so project URLs, databases and service
containers answer at their own addresses there. SOCKS-over-SSH and SSH
ProxyJump terminate at sshd on the VM and never traverse the forward
chain at all. See "The container-subnet firewall" below.

## How the laptop reaches the VM

The laptop reaches the whole container subnet — project HTTPS on the
VM's `.2`, databases, service containers, plus dnsmasq and the portal's
caddy on the gateway `.1`. What is sealed is the *LAN/public*
side of the VM, not the laptop's paths in. There are two host-side
paths, both set up by `mpd-virt`:

- **Simple — SOCKS over SSH (recommended for a new developer).** `ssh -N
  mpd-<NNN>-socks` opens a SOCKS5 proxy on `127.0.0.1:1080` that tunnels
  through the VM over plain SSH. Point a *dedicated browser* at it with
  remote DNS on, and `*.mpd.test` resolves via the VM's dnsmasq and every
  address in the subnet answers. No `sudo`, no overlay; one VM at a time.
  Trust the mpd CA in that browser (or the System Keychain) and HTTPS
  just works.
- **Advanced — WireGuard overlay (mpd-proxy, for daily multi-VM use).**
  `mpd-proxy` runs one WireGuard `utun` on the laptop and adds each VM as
  a peer routing the whole `10.163.<NNN>.0/24`, plus one split-DNS resolver
  (`/etc/resolver/mpd.test` → mpd-proxy → the right VM's dnsmasq). Several
  VMs are reachable at once, transparently, for *every* app — not just a
  browser. Needs `sudo mpd-proxy up` once.

Both reach the whole container subnet — SOCKS via sshd on the VM, the
overlay via `wg0` (which the in-VM firewall exempts; routing into the
subnet from the LAN is dropped). Both coexist with a corporate VPN.
**Trust** is the same either way: the mpd root CA in the System Keychain
(transparent, every app) or imported into the dedicated browser (no
`sudo`) makes `*.mpd.test` HTTPS trusted.

### A third path: don't reach in at all

Both paths above exist to export the VM's world to a *remote* browser —
they carry routing, DNS and certificate trust across to the client. The
alternative is to leave all three where they already work and move the
browser instead: run the desktop inside the VM (`gnome-install`), open
RDP (`rdp-start`), and view it. Chromium in that session resolves `.test`
through the VM's own dnsmasq and already trusts the mpd CA, so nothing
about the network has to be true on the client. Only pixels cross.

That makes it the *simplest* path, not a fallback — and on a tablet it is
the only one. iPadOS has no per-app SOCKS setting and configures a system
proxy per Wi-Fi network, so SOCKS cannot work on a cellular connection at
all; trusting the CA means installing a profile and granting system-wide
trust on a personal device; and mpd-proxy is a macOS binary. Microsoft's
Remote Desktop client (iPadOS, Android, macOS, Windows) needs none of it.

The cost is the one mpd door authenticated by a password rather than a
key, so reach it over a private network, a bastion or a zero-trust
tunnel — never the open internet — and close it with `rdp-stop`. See
[`security.md`](security.md) and the day-to-day steps in
[`usage.md`](usage.md#the-vms-desktop-and-reaching-it-from-a-tablet).

### The container-subnet firewall

`mpd --vm-setup` installs `mpd-firewall.service` — an independent nftables
table whose forward chain drops NEW connections into `10.163.<NNN>.0/24`
from any interface but `mpdbr0` and `wg0`, while leaving
`established,related` and the container→internet masquerade (netavark's
own table) untouched. So a container reaches out to the internet, the VM
reaches its own containers, and the developer's laptop reaches the whole
subnet through the WireGuard overlay — but nothing on the LAN or the
public side can open a connection to a container IP. (SOCKS and ProxyJump
are unaffected either way: they terminate at sshd and never traverse the
forward chain.) Combined with caddy and dnsmasq binding only `.1` (never
the LAN address), the VM's whole external surface is `tcp/22` (sshd) +
`udp/51820` (WireGuard), both cryptographic — which is what lets an mpd
VM run safely anywhere reachable by IP.

## Per-VM addressing

`<NNN>` above is the VM's id, taken from its hostname `mpd-<NNN>`
(`net.Current()`; ids run 100..254 — managed platforms also use the id
as the last octet of the VM's static IP). It is the discriminator in
**both** halves of
the addressing: the third octet of the container subnet, and the first
label of the DNS zone. Nothing else varies: the project frontdoor is
always `.2`, databases take `.10–.99`, extra service containers
`.100–.199` (each service pins its own octet: mailpit `.100`, adminer
`.102`, selenium `.103`), and the resolver and the status page answer on
the gateway `.1`. Both `.1` and `.2` are the VM itself — the container
IPAM range starts at `.10` so netavark can never hand either out.

```
VM 150:  10.163.150.0/24   zone 150.mpd.test   moodle45.150.mpd.test
VM 180:  10.163.180.0/24   zone 180.mpd.test   moodle45.180.mpd.test
```

Name patterns under the zone follow the addressing (`go/internal/net/`
composes them all):

| Name                          | Points at                                     |
| ----------------------------- | --------------------------------------------- |
| `<NNN>.mpd.test` (apex)       | `.1` — the portal, via the VM's caddy         |
| `<project>.<NNN>.mpd.test`    | `.2` — the project caddy serves the project   |
| `<name>.db.<NNN>.mpd.test`    | `.10–.99` — a database container              |
| `<name>.svc.<NNN>.mpd.test`   | `.100–.199` — an extra service container      |
| `vm.<NNN>.mpd.test`           | the VM's own LAN IP (diagnostic — see below)  |

(`svc` and `vm` are reserved project names so a project can never shadow
these records.)

This is what makes **several VMs reachable at the same time**. The host
holds one route and one resolver entry per VM; the routes are to
disjoint /24s, and the resolver entries cover disjoint domains (macOS
`resolver(5)` matches longest suffix, so per-VM files never conflict).

The bare `mpd.test` apex does **not** resolve, deliberately: with two
VMs up it could only mean one of them, and mpd prefers a name that fails
to a name that silently picks. `<NNN>.mpd.test` is the apex, and it
resolves to that VM's gateway address, where caddy terminates TLS and
proxies to `mpd --web` on loopback.

One CA covers every VM — its name constraint (`permitted;DNS.0 =
.mpd.test`) already permits arbitrary depth beneath the root domain, so
adding a VM needs no new trust operation.

Changing an existing VM's ID is not a supported operation: the Podman
network's subnet is fixed at create time, so `mpd --vm-setup` refuses when
it finds a network that disagrees with the VM's id and prints the
teardown/recreate steps.

## One record store: `/etc/hosts`

Every name mpd publishes is a line in one managed block in the VM's
`/etc/hosts`:

```
# BEGIN mpd
# DNS records for 200.mpd.test, managed by mpd. Edits are overwritten.
10.163.200.1 200.mpd.test
10.1.10.200 vm.200.mpd.test
10.163.200.103 selenium.svc.200.mpd.test
10.163.200.2 docs.200.mpd.test
10.163.200.2 m45.200.mpd.test
10.163.200.11 postgres-18.db.200.mpd.test
10.1.10.100 forge.mpd.test
# END mpd
```

The block is recomputed from state — `projects.json`, `services.json`,
the database containers' pinned addresses, the LAN hosts file mpd-virt
pushes in — on every change (`mpd init/start/reset/delete`, database and
service verbs, `--vm-start`, `--vm-setup`) and rewritten only when it
differs. Nothing outside the fences is mpd's; the distro's lines and
anything you add by hand stay as they are.

Two readers, one file:

- **The VM itself** reads it through glibc — `files` leads the `hosts:`
  line of `nsswitch.conf` on every Debian install — so the VM resolves its
  own zone without any resolver in the path. No systemd-resolved routing,
  no search domain, nothing to race at boot.
- **dnsmasq** reads the same file (its default) and serves it to everyone
  else.

That is what fixed names failing for minutes after a VM start: a chain of
resolvers with negative caches was asked about a name before it existed.
Now the name is in a file that exists before anything boots, and a service
that is not up yet answers *connection refused* rather than a cached
NXDOMAIN.

## One resolver, on the VM

dnsmasq runs **on the VM** — Debian's `dnsmasq-base` package under mpd's
own `mpd-dnsmasq.service`, configured from `/var/lib/mpd/conf/dnsmasq.conf`
(rendered by `mpd --vm-setup`; edits are overwritten). It is not a
container, and there is no second resolver anywhere in the path.

Everyone but the VM asks it at the same address, `10.163.<NNN>.1`:

| Client | How it gets there |
| --- | --- |
| Containers | `--dns 10.163.<NNN>.1` at create time, one nameserver, no fallback, `--hosts-file=none` |
| The VM | not through dnsmasq at all — glibc reads `/etc/hosts` |
| The laptop | mpd-proxy split DNS (`/etc/resolver/mpd.test`), or SOCKS remote DNS — see above |

Podman's own DNS is **off** (`--disable-dns` on the network). Otherwise
aardvark-dns would hold port 53 on the gateway, which is where dnsmasq
listens — and it answered nothing mpd asks for, since every mpd name is
fully qualified and served here.

Containers get exactly one nameserver on purpose. Left to itself podman
copies the VM's resolv.conf, which lists the upstream link resolver as a
fallback — so a `.test` name would quietly escape to public DNS whenever
the local resolver blinked, and answer NXDOMAIN instead of failing
visibly. They also get `timeout:1 attempts:2`, because glibc's stock
`timeout:5 attempts:2` turns any momentary gap into a ten-second stall.
And they get **no base hosts file** (`--hosts-file=none`): podman would
otherwise seed a container's `/etc/hosts` from the VM's, and since the
VM's now carries mpd's records, every container would start with a
snapshot that glibc's `files` lookup keeps answering from long after the
records moved. A container's `/etc/hosts` holds only podman's own
entries; everything mpd publishes comes from dnsmasq.

### Authoritative for `.test`, forwarding for everything else

`local=/test/` makes dnsmasq authoritative for the whole reserved TLD, not
just `mpd.test`: `.test` is RFC 6761 reserved and must never reach a public
resolver. Unknown names under it return NXDOMAIN immediately, and AAAA
queries on names with only A records return NoData. That is what avoids
the multi-second `getaddrinfo` stalls that happen when AAAA queries for
a `.test` name leak to public DNS. A VM has exactly one resolver and
no business answering for another VM's zone, so NXDOMAIN for a foreign
zone is the correct in-VM answer.

Everything else is forwarded to whatever the VM's own `/etc/resolv.conf`
lists — dnsmasq's default, and whoever maintains that file (dhcpcd on a
headless install, NetworkManager on a desktop, systemd-resolved on a cloud
image) keeps it current; dnsmasq polls it, so switching networks needs no
restart. Where the file names systemd-resolved's `127.0.0.53` stub, that
cannot loop: `local=/test/` means a `.test` name is never forwarded at
all, and nothing routes `.test` back to dnsmasq.

There is no `MPD_DNS_UPSTREAM` to configure and no hardcoded public DNS in
the path.

### Changing a record reloads, never restarts

After the block changes, mpd sends dnsmasq a SIGHUP (`systemctl reload
mpd-dnsmasq`). dnsmasq re-reads `/etc/hosts` and `/etc/resolv.conf` and
clears its cache; queries in flight are answered, not dropped.

Records are kept in `/etc/hosts` and not as `address=/host/ip` fragments
in a `conf-dir=`, because dnsmasq reads config files only at startup —
not even SIGHUP re-reads them — so every record change would restart the
resolver. The restart takes 0.2s, but a client whose query is in flight
pays glibc's full timeout: **10 seconds** of `Temporary failure in name
resolution` for every other project on the VM, per record change. Hosts
lines also answer only the exact name written; `address=/x/ip` answers
for every name beneath `x` too.

### cloud-init and `/etc/hosts`

On a cloud-init image the seed's user-data usually says
`manage_etc_hosts: true` — Proxmox always writes it, and its UI cannot
turn it off — which makes cloud-init's `update_etc_hosts` module rewrite
`/etc/hosts` from a template on **every boot**. Setting
`manage_etc_hosts: false` under `/etc/cloud/` does not help: the instance
user-data outranks it. What does work is cloud-init's own override for
module lists, so `mpd --vm-setup` installs
`/etc/cloud/cloud.cfg.d/99-mpd.cfg` (from `assets/vm/`), which replaces
every stage's module list with just `growpart` + `resizefs`. That also
freezes the VM's identity: Proxmox issues a new instance-id whenever its
cloud-init tab is edited, and without the drop-in the next boot would
re-run the hostname, user and `ssh` modules — the last one regenerates the
host keys mpd-virt pinned. Fixing the IP in the hypervisor still applies
(network config is not a module), and enlarging the disk still grows the
filesystem. A VM without cloud-init (a Debian installer VM) needs nothing:
nothing there touches `/etc/hosts` after installation.

### Binding the bridge

The resolver binds only `10.163.<NNN>.1`, never the VM's LAN address:
nothing mpd serves is published beyond the VM.

`mpdbr0` is a **static bridge**: a small systemd oneshot
(`mpd-bridge.service`, ordered before the resolver) creates it at boot
with the gateway address, rather than leaving it to netavark, which
would create the bridge only when the first container attaches. So
`10.163.<NNN>.1` exists before any container: the resolver binds it at
boot, caddy binds the gateway without racing, and netavark simply
attaches container veths to the existing bridge.

The resolver still uses `bind-dynamic` with `interface=mpdbr0` — it
tolerates dnsmasq racing the bridge unit and rebinds if the bridge is
ever recreated. The `interface=` line is what makes that work: with
`listen-address=` alone dnsmasq binds nothing when the address shows up
later, stays `active` with no listener, and every name in the zone
fails until something restarts it.

Belt and braces: both `mpd --vm-setup` and `mpd --vm-start` check that
the resolver *answers*, not merely that the unit is active, and restart
it once if it does not (`vm.EnsureDnsmasqResolving`). If it still does
not answer the command fails loudly rather than reporting a green setup
over a VM that resolves nothing.

To recognise it by hand: `sudo ss -lnup | grep dnsmasq` should show *two*
listeners, `127.0.0.1:53` and `10.163.<NNN>.1:53`. Only the first means
you have hit this; `sudo systemctl restart mpd-dnsmasq` fixes it
immediately.

## Diagnostic record: `vm.<NNN>.mpd.test`

In addition to the service and project records, the block carries
one special record ("vm" is a reserved project name for this reason):

```
vm.<NNN>.mpd.test → the VM's own LAN IP
```

i.e. the **VM's own LAN IP** (e.g. `10.211.55.125` for a managed VM),
not a container subnet address — the one place the LAN address appears
inside the VM. It is read live off the interface on every reconcile
(`vm.PrimaryIP()`, never recorded), so a VM that reboots onto a different
network republishes the new address on `--vm-start`, and skipped when the
VM has no address yet.

The purpose is identity verification: `mpd-virt`'s reachability check on
the Mac queries this name and compares the answer to the VM's known IP. A
match proves
the Mac is talking to **this specific VM's** dnsmasq — not some other
resolver that happens to know about the zone. With per-VM subnets a
reply from `10.163.<NNN>.1` can only be that VM's resolver, so this is
now a confirmation rather than a disambiguation — but it is cheap and it
catches registry IP drift on the host side.

## SSH access

From the laptop, straight to the VM's sshd over plain SSH — no overlay,
no SOCKS, and no second hop: PHP, the tools, the IDE backend and the AI
agent all run on the VM.

```
# ~/.ssh/config (written automatically by mpd-virt):
Host mpd-<NNN> mpd-<NNN>-vm <the VM's address>
    HostName <the VM's address>
    User user
```

The bare name is the machine you work on; `-vm` is a synonym for it.
IDEs (PHPStorm Gateway, VS Code Remote-SSH) need no ProxyJump.

Inside the VM there is nothing to alias: you are already there.

mpd assumes your laptop user and VM user share the same name. Set up the
VM with the same account name as your laptop login.

See also: [README.md](README.md), [security.md](security.md)
