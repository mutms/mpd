# Machine Networking (mpd VM)

How the host laptop reaches mpd's container subnet inside the VM.

The host-side bits (static route, scoped DNS, CA trust) are configured
by the **mpd-virt** orchestrator binary (separate repo) — not by the
in-VM `mpd` binary. This document describes the topology and the
host↔VM↔containers data path; for the actual host commands see
`mpd-virt`'s own documentation.

## Topology

```text
Laptop (macOS — primary)
  |
  | hypervisor network + static route:  10.163.<NNN>.0/24 → <VM IP>
  |
VM (Debian Trixie)              hostname: mpd-<NNN>
  |
  Podman (rootful) bridge:  mpd0  10.163.<NNN>.1/24
   |    Three VM processes bind this address, and nothing else does:
   |      dnsmasq :53   — DNS for *.test
   |      caddy   :443  — the zone apex (mpd --web) and adminer, both HTTPS
   |
   `mpd-internal` Podman network    10.163.<NNN>.0/24  (podman DNS disabled)
     |
     +-- mpd-service-adminer     10.163.<NNN>.6   (plain HTTP; caddy fronts it)
     +-- DB containers           10.163.<NNN>.30–.99
     +-- runtime containers      10.163.<NNN>.100+ (full dev access via SSH)
```

The bridge is named `mpd0` rather than taking podman's `podman0`/`podman1`
counter, whose value depends on what other networks were created first.
dnsmasq names that interface in its config, so a name that drifts is a
name that silently stops resolving.

The VM runs `net.ipv4.ip_forward=1` (set by `bootstrap/30-networking.sh`)
so packets from the laptop transit the VM and reach containers via
`mpd0`.

## How the laptop reaches containers

There is no tunnel. The laptop already reaches the VM over the
hypervisor's own network (Parallels Shared, libvirt default, Hyper-V
Default Switch), and the container subnet hangs off that:

- **Route** — `10.163.<NNN>.0/24` via the VM's IP, installed on the host by
  `mpd-virt` (persistent where the OS supports it; re-asserted on
  `start` otherwise). This is what makes container IPs reachable.
- **DNS** — a *scoped* resolver entry pointing `*.<NNN>.mpd.test` at that
  VM's resolver (`10.163.<NNN>.1`): `/etc/resolver/<NNN>.mpd.test` on
  macOS, an NRPT rule for `.<NNN>.mpd.test` on Windows, a
  systemd-resolved drop-in with `Domains=~<NNN>.mpd.test` on Linux.
  Scoped, so only that VM's zone goes to that VM — everything else keeps
  using the host's normal resolvers.
- **Trust** — mpd's local CA is installed in the host's system trust
  store (one-time at setup) so HTTPS just works.

Those three facts are the whole client contract, and they're identical
on macOS, Linux, and Windows. A scoped route plus scoped DNS coexists
cleanly with a corporate VPN; nothing has to be toggled on or off to
use mpd.

## Per-VM addressing

`<NNN>` above is the VM's `MPD_VM_ID` — the last octet of its static IP
(`000` for a sandbox VM). It is the discriminator in **both** halves of
the addressing: the third octet of the container subnet, and the first
label of the DNS zone. Nothing else varies: adminer is always `.6`,
runtimes `.100+`, and both the resolver and the status page answer on the
gateway `.1` because they run on the VM rather than in a container.

```
VM 150:  10.163.150.0/24   zone 150.mpd.test   moodle45.150.mpd.test
VM 180:  10.163.180.0/24   zone 180.mpd.test   moodle45.180.mpd.test
sandbox: 10.163.0.0/24     zone 000.mpd.test
```

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
| The laptop | scoped resolver entry (see above) |

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
names. Publishing a record is a file write and nothing else — `mpd create`,
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

It uses `bind-dynamic` with `interface=mpd0`, because podman does not
create the bridge until the first container attaches to the network —
which, on a fresh VM, is after the unit starts. `bind-dynamic` watches for
the interface appearing and binds then. The `interface=` line is what makes
that work: with `listen-address=` alone dnsmasq binds nothing when the
address shows up later, stays `active` with no listener, and every name in
the zone fails until something restarts it.

One consequence worth knowing: if *no* container has ever started, the
bridge does not exist and the resolver has nothing to bind. `mpd
--vm-setup` creates adminer, which is enough.

There is also a race, and it has bitten a real VM. dnsmasq scans the
interfaces once at startup and then watches netlink for later ones; an
interface appearing in the window between those two steps is missed
**permanently**. At boot the resolver starts before podman has recreated
the bridge, so the window is real — and a VM that loses the race comes up
with a resolver that is `active`, bound to `127.0.0.1` only, and answering
nothing. Every name on the VM fails, which reads like anything but a DNS
problem.

Both `mpd --vm-setup` and `mpd --vm-start` therefore check that the
resolver *answers*, not merely that the unit is active, and restart it
once if it does not (`vm.EnsureDnsmasqResolving`). By then the bridge
exists, so the startup scan finds it. If it still does not answer the
command fails loudly rather than reporting a green setup over a VM that
resolves nothing.

To recognise it by hand: `sudo ss -lnup | grep dnsmasq` should show *two*
listeners, `127.0.0.1:53` and `10.163.<NNN>.1:53`. Only the first means
you have hit this; `sudo systemctl restart mpd-dnsmasq` fixes it
immediately.

## Diagnostic record: `vm.service.<NNN>.mpd.test`

In addition to the runtime / service / project records, dnsmasq serves
one special record:

```
vm.service.<NNN>.mpd.test → <MPD_VM_IP from /var/lib/mpd/conf/platform.env>
```

i.e. the **VM's own static IP** (e.g. `10.211.55.125` for a managed VM),
not a container subnet address. It's written into `services.hosts` by
`dnsmasq.Manager.EnsureServiceRecords` and skipped on sandbox VMs (where
`MPD_VM_IP` is empty).

The purpose is identity verification: `mpd-virt diag` on the Mac queries
this name and compares the answer to the VM's known IP. A match proves
the Mac is talking to **this specific VM's** dnsmasq — not some other
resolver that happens to know about the zone. With per-VM subnets a
reply from `10.163.<NNN>.1` can only be that VM's resolver, so this is
now a confirmation rather than a disambiguation — but it is cheap and it
catches registry IP drift on the host side.

## SSH access to runtime containers

Two parallel paths, both fine:

**Direct** — container names resolve and container IPs route, so:

```
ssh user@php.runtime.<NNN>.mpd.test
```

**Via SSH ProxyJump through the VM** — works even without host-side
route/DNS config, since the VM's address is reachable via the
hypervisor's own network:

```
# ~/.ssh/config:
Host mpd-<octet>-php
    HostName php.runtime.<NNN>.mpd.test
    User user
    ProxyJump mpd-<octet>
```

IDEs (PHPStorm Gateway, VS Code Remote-SSH) configure ProxyJump the same
way. mpd-virt writes these SSH config entries automatically.

mpd assumes your laptop user, VM user, and runtime user share the same
name — that's what makes the bare jump-host form work without explicit
`user@`. Set up the VM with the same account name as your laptop login.

See also: [README.md](README.md), [SECURITY.md](SECURITY.md)
