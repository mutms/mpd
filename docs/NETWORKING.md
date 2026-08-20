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
  │  Static bridge:  mpdbr0  10.163.<NNN>.1/24
  │    Two VM processes bind this address (nothing binds the LAN IP):
  │      dnsmasq :53   — DNS for *.test
  │      caddy   :443  — the zone apex only (the portal, mpd --web), HTTPS
  │
  `mpd-internal` Podman network    10.163.<NNN>.0/24  (podman DNS disabled)
    │   SEALED from the LAN by an nft firewall (mpd-firewall.service);
    │   only mpdbr0 and wg0 may route in
    +-- mpd-<NNN>-runtime       10.163.<NNN>.2     (in-runtime caddy :443
    │                            terminates project HTTPS; SSH ProxyJump)
    +-- DB containers           10.163.<NNN>.10–.99
    +-- extra service containers 10.163.<NNN>.100–.199  (plain HTTP:
                                 mailpit .100, adminer .102, seleniumv1 .103)
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

The laptop reaches the whole container subnet — project HTTPS at the
runtime's `.2`, databases, service containers, plus dnsmasq and the
portal's caddy on the gateway `.1`. What is sealed is the *LAN/public*
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
label of the DNS zone. Nothing else varies: the runtime is always `.2`,
databases take `.10–.99`, extra service containers `.100–.199` (each
service pins its own octet: mailpit `.100`, adminer `.102`, seleniumv1
`.103`), and both the resolver and the status page answer on the
gateway `.1` because they run on the VM rather than in a container.

```
VM 150:  10.163.150.0/24   zone 150.mpd.test   moodle45.150.mpd.test
VM 180:  10.163.180.0/24   zone 180.mpd.test   moodle45.180.mpd.test
```

Name patterns under the zone follow the addressing (`go/internal/net/`
composes them all):

| Name                          | Points at                                     |
| ----------------------------- | --------------------------------------------- |
| `<NNN>.mpd.test` (apex)       | `.1` — the portal, via the VM's caddy         |
| `<project>.<NNN>.mpd.test`    | `.2` — the runtime's caddy serves the project |
| `runtime.<NNN>.mpd.test`      | `.2` — the runtime container itself           |
| `<name>.db.<NNN>.mpd.test`    | `.10–.99` — a database container              |
| `<name>.svc.<NNN>.mpd.test`   | `.100–.199` — an extra service container      |
| `vm.<NNN>.mpd.test`           | the VM's own LAN IP (diagnostic — see below)  |

(`runtime`, `svc` and `vm` are reserved project names so a project can
never shadow these records.)

This is what makes **several VMs reachable at the same time**. The host
holds one route and one resolver entry per VM; the routes are to
disjoint /24s, and the resolver entries cover disjoint domains (macOS
`resolver(5)` matches longest suffix, so per-VM files never conflict).
Under the previous flat model every VM served the same `10.163.0.0/24`,
so the host could route to only one of them at a time — regardless of
naming.

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

## One resolver, on the VM

dnsmasq runs **on the VM** — Debian's `dnsmasq-base` package under mpd's
own `mpd-dnsmasq.service`, configured from `/var/lib/mpd/conf/dnsmasq.conf`
(rendered by `mpd --vm-setup`; edits are overwritten). It is not a
container, and there is no second resolver anywhere in the path.

Everything asks it at the same address, `10.163.<NNN>.1`:

| Client | How it gets there |
| --- | --- |
| Containers | `--dns 10.163.<NNN>.1` at create time, one nameserver, no fallback |
| The VM | systemd-resolved drop-in: `DNS=10.163.<NNN>.1`, `Domains=~mpd.test` |
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

### Authoritative for `.test`, forwarding for everything else

`local=/test/` makes dnsmasq authoritative for the whole reserved TLD, not
just `mpd.test`: `.test` is RFC 6761 reserved and must never reach a public
resolver. Unknown names under it return NXDOMAIN immediately, and AAAA
queries on names with only A records return NoData. That is what avoids
the multi-second `getaddrinfo` stalls that used to happen when AAAA queries
leaked to public DNS for a `.test` name. A VM has exactly one resolver and
no business answering for another VM's zone, so NXDOMAIN for a foreign
zone is the correct in-VM answer.

Everything else is forwarded using `/run/systemd/resolve/resolv.conf` — the
*real* per-link upstream nameservers managed by systemd-resolved, **not**
the `127.0.0.53` stub, which resolves `.test` by asking dnsmasq and would
therefore loop. dnsmasq watches that file and adapts when the host switches
networks (corporate VPN, Wi-Fi) without a restart.

That file also lists dnsmasq's *own* address, because mpd points resolved
at it for `.test`. Not a loop either: dnsmasq drops any upstream that is
one of its own addresses, logging `ignoring nameserver <ip> - local
interface`, and forwards to the remaining per-link ones.

There is no `MPD_DNS_UPSTREAM` to configure and no hardcoded public DNS in
the path.

### Records are files, and changing one restarts nothing

Records live as hosts files in `/var/lib/mpd/state/dns/`, read via
dnsmasq's `hostsdir=`. dnsmasq watches that directory and re-reads it on
every add, change and remove, flushing the cache for just the affected
names. Publishing a record is a file write and nothing else — `mpd init`,
`mpd start`, `mpd stop` and `mpd delete` never signal or restart the
resolver.

This matters more than it sounds. Records used to be `address=/host/ip`
fragments in a `conf-dir=`, which dnsmasq reads only at startup — not even
SIGHUP re-reads a config file — so every record change restarted the
resolver. The restart itself took 0.2s, but a client whose query was in
flight paid glibc's full timeout: a measured **10.013 seconds** of
`Temporary failure in name resolution` for every other project on the VM,
per record change.

The format change is not just serialisation. `address=/x/ip` answers for
`x` **and every name beneath it**, so it was a wildcard being used for
exact names; a hosts entry answers only the name written. Since mpd
enumerates every name it publishes, exact match is what was always meant,
and unknown names under the zone now NXDOMAIN by construction rather than
by careful use of a wildcard.

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

In addition to the runtime / service / project records, dnsmasq serves
one special record ("vm" is a reserved project name for this reason):

```
vm.<NNN>.mpd.test → the VM's own LAN IP
```

i.e. the **VM's own LAN IP** (e.g. `10.211.55.125` for a managed VM),
not a container subnet address. It's written into `services.hosts` by
`dnsmasq.Manager.EnsureServiceRecords` and skipped when no address can
be read off an interface (`vm.PrimaryIP()` — read live, never recorded).

The purpose is identity verification: `mpd-virt`'s reachability check on
the Mac queries this name and compares the answer to the VM's known IP. A
match proves
the Mac is talking to **this specific VM's** dnsmasq — not some other
resolver that happens to know about the zone. With per-VM subnets a
reply from `10.163.<NNN>.1` can only be that VM's resolver, so this is
now a confirmation rather than a disambiguation — but it is cheap and it
catches registry IP drift on the host side.

## SSH access to the runtime container

From the laptop, **via SSH ProxyJump through the VM** — it rides plain
SSH to the VM's sshd, which reaches the runtime over the internal
bridge, so it needs no overlay or SOCKS and works even when mpd-proxy
is down.

```
# ~/.ssh/config (written automatically by mpd-virt):
Host mpd-<NNN>
    HostName runtime.<NNN>.mpd.test
    User user
    ProxyJump mpd-<NNN>-vm

Host mpd-<NNN>-vm
    HostName <the VM's address>
    User user
```

The bare name is the runtime because that is where the work happens; the
VM that manages the containers takes the `-vm` suffix. IDEs (PHPStorm
Gateway, VS Code Remote-SSH) configure ProxyJump the same way.

**From a terminal inside the VM** — `mpd --vm-setup` writes
`mpd-<NNN>-runtime` into the VM's own `~/.ssh/config`, minus the
ProxyJump (the runtime subnet is directly attached there); the bare
`runtime` and the FQDN also answer. The short host-side spelling cannot
be reused here: in the VM `mpd-<NNN>` is that machine's own hostname.
What is consistent instead is the *prompt* — the runtime's reads
`mpd-<NNN>` and the VM's `mpd-<NNN>-vm`, matching the host-side aliases,
without either hostname being changed. Details in
[`USAGE.md`](USAGE.md#ssh-into-the-runtime).

Note what is *not* here: short names as dnsmasq **records**. dnsmasq
publishes only fully-qualified names, because this resolver is
authoritative for the whole `.test` tree (`local=/test/`) — a bare
`runtime` record would be a name with no zone, answered finally for every
container on the VM.

The VM itself still resolves the short form, by a narrower route:
`--vm-setup` gives systemd-resolved this VM's zone as a search domain
(`Domains=~mpd.test <NNN>.mpd.test`), so `runtime` is qualified to
`runtime.<NNN>.mpd.test` before it ever reaches dnsmasq. That is scoped
to the VM's own resolution — containers, which ask dnsmasq directly,
never see it.

It exists for SSH clients that offer a jump host but no `~/.ssh/config`:
ProxyJump has the *jump host* resolve the target through libc, so an ssh
alias cannot help there and a resolvable name must. jump = the VM,
host = `runtime`.

mpd assumes your laptop user, VM user, and runtime user share the same
name — that's what makes the bare jump-host form work without explicit
`user@`. Set up the VM with the same account name as your laptop login.

See also: [README.md](README.md), [SECURITY.md](SECURITY.md)
