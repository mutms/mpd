# Proposal: per-VM DNS zone and container subnet

**Status:** **implemented** (2026-07-20) — kept as the design record
**Scope:** in-VM `mpd` binary + host-side `mpd-virt` (lockstep change)
**Migration:** none — flag day, delete and recreate VMs

> **Landed.** Both halves ship: `Mpd.Net` (`mpd/Net.swift`) in this repo
> and `MpdVirt.Net` in `mpd-virt-macos`, plus the `setup/linux` and
> `setup/windows` client bundles. Verified with two concurrent VMs (150
> and 180) reachable from one Mac at the same time — the outcome this
> proposal existed to deliver.
>
> Deviations from the plan below, all deliberate:
>
> - **`vm.service.<zone>` is kept**, not retired. The zone now proves
>   which VM answered, so the record is redundant for that purpose, but
>   it is a cheap independent diagnostic and it catches host-side
>   registry IP drift.
> - **Route persistence (LaunchDaemon) is deferred.** The manual
>   `route add` stays until it proves annoying enough to automate.
> - **Two extra fixes were needed** that the plan didn't anticipate:
>   the service certificate had no SAN-drift detection (so it kept a
>   cert for the old zone), and `--setup` never reconciled stale
>   per-runtime dnsmasq records. Both are now handled.
> - **`mpd --setup` refuses** when the existing Podman network's subnet
>   disagrees with the VM's id, rather than reporting success on a
>   network it cannot change in place.
>
> Canonical description of the shipped behavior:
> [`docs/NETWORKING.md`](../NETWORKING.md).

## Problem

Every mpd VM builds an identical address space and an identical DNS
zone:

- Container subnet `10.163.0.0/24` on every VM (`mpd/Mpd.swift:52`)
- dnsmasq at `10.163.0.3`, portal `.4`, fileaccess `.5`, adminer `.6`,
  DBs `.30–.99`, runtimes `.100+` — same on every VM
- Flat zone: `<project>.mpd.test`, `<rt>.runtime.mpd.test`,
  `<db>.db.mpd.test`, `<svc>.service.mpd.test`

With one VM that is fine. With several — two Parallels VMs today,
Parallels plus Proxmox once remote hosting lands — it breaks in two
independent ways:

1. **Name collision.** A `moodle45` project on VM 222 and on VM 150 are
   both `moodle45.mpd.test`. Nothing distinguishes them, in the browser
   or in `~/.ssh/config`.
2. **Address collision.** Both VMs' runtimes live at `10.163.0.100`.
   The workstation can only route `10.163.0.0/24` to one next hop, so
   only one VM is reachable at a time — regardless of naming.

Today this is worked around by toggling WireGuard tunnels. That is the
symptom being removed. Note that (2) is the binding constraint: fixing
names alone changes nothing about reachability.

There is also a diagnosability cost. `10.163.0.100` tells you nothing
about which VM answered, which is why `vm.service.mpd.test` exists at
all (`docs/NETWORKING.md`, `mpd/Service/ServiceDnsmasq.swift:185-186`).

## Proposal

Use the existing `MPD_VM_ID` as the discriminator in **both** the DNS
zone and the third IP octet.

`MPD_VM_ID` is already a 3-digit value in `[100, 254]` for managed VMs
(the VM's static-IP octet) and `000` for sandbox
(`mpd/VM/Platform.swift:7-9`, written by `bootstrap/30-networking.sh:38-50`).
It is a valid octet by construction, so it can be used directly.

### Addressing

| | VM 222 | VM 150 | sandbox (000) |
|---|---|---|---|
| subnet | `10.163.222.0/24` | `10.163.150.0/24` | `10.163.0.0/24` |
| gateway (VM itself) | `10.163.222.1` | `10.163.150.1` | `10.163.0.1` |
| dnsmasq | `10.163.222.3` | `10.163.150.3` | `10.163.0.3` |
| portal | `10.163.222.4` | `10.163.150.4` | `10.163.0.4` |
| fileaccess / adminer | `.5` / `.6` | `.5` / `.6` | `.5` / `.6` |
| DBs | `10.163.222.30–.99` | `10.163.150.30–.99` | `.30–.99` |
| runtimes | `10.163.222.100+` | `10.163.150.100+` | `.100+` |

The host part is unchanged everywhere. Only the third octet moves, and
it equals the VM ID. Sandbox keeps `10.163.0.0/24` — `000` is not a
special case, it is just the zeroth VM.

### DNS

Each VM owns a subdomain of `mpd.test` named for its ID:

```
moodle45.222.mpd.test    →  10.163.222.100
mutms.150.mpd.test       →  10.163.150.100
php.runtime.222.mpd.test →  10.163.222.100
pg17.db.222.mpd.test     →  10.163.222.30
portal.service.222.mpd.test → 10.163.222.4
222.mpd.test             →  10.163.222.4   (zone apex → portal)
```

The VM segment is the **parent** zone, not a leaf. That is what makes
the workstation config one rule per VM (`222.mpd.test → 10.163.222.3`)
rather than one rule per project, and it leaves room to delegate the
zone to a real nameserver later. It also gives usable browser
autocomplete: typing `222` surfaces everything on that VM.

### Why both halves are required

Per-VM names without per-VM subnets still cannot route two VMs at
once. Per-VM subnets without per-VM names leaves two different hosts
answering to `moodle45.mpd.test`. The pair is the unit of work.

## Design decisions

**Zone apex replaces bare `mpd.test`.** `mpd.test` stops resolving.
Today it is a `host-record` pointing at the portal, deliberately not an
`address=` wildcard (`mpd/Service/ServiceDnsmasq.swift:172-176`). Under
this proposal `222.mpd.test` takes that role. Keeping a bare `mpd.test`
alias would reintroduce exactly the ambiguity being removed — with two
tunnels up, it would resolve to whichever VM won — and mpd prefers
deterministic behavior over convenience fallbacks (`AGENTS.md`).
Sandbox is included: `000.mpd.test`, no exception.

**Host-side resolution becomes per-zone.** The workstation gets one
scoped resolver entry per VM, all of which coexist:

- macOS: `/etc/resolver/222.mpd.test` → `nameserver 10.163.222.3`
  (macOS resolver(5) longest-suffix match, so per-VM files never
  conflict with each other)
- Windows: NRPT rule for `.222.mpd.test`
  (`setup/windows/lib/configure-client.ps1:8,25`)
- Linux: resolved drop-in with `Domains=~222.mpd.test`
  (`setup/linux/lib/configure-client.sh:144-146`)

A VM whose route is down simply fails to resolve, which is the correct
and legible outcome.

> **Correction to `docs/NETWORKING.md`.** That doc claims `DNS =
> 10.163.0.3` is set in the WireGuard tunnel config and that there is
> "no `/etc/resolver/` file". Both statements are false as of
> `mpd-virt-macos@0d17c5e`. `WireGuard.swift:183-195` deliberately
> omits `DNS =` — wireguard-apple treats it as a *global* tunnel
> resolver with no `matchDomains` split-DNS, which would send every Mac
> DNS query to the untrusted VM — and scoped resolution already goes
> through a hand-created `/etc/resolver/mpd.test`. `NETWORKING.md`
> should be corrected independently of this proposal.
>
> This means DNS was never what forced tunnel switching. The real
> causes are all addressing collisions, and they are enumerated in the
> companion proposal in the `mpd-virt-macos` repo.

**In-VM resolution stays broad.** dnsmasq keeps `local=/mpd.test/`
(`assets/services/dnsmasq/dnsmasq.conf:20`) and the in-VM resolved
drop-in keeps `Domains=~mpd.test` (`mpd/VM/DNS.swift:53`). A VM has
exactly one dnsmasq and no business resolving another VM's zone —
NXDOMAIN for `foo.150.mpd.test` from inside VM 222 is correct.

**`vm.service.mpd.test` is retired.** Its only purpose was proving
which VM's dnsmasq answered (`docs/NETWORKING.md`). The zone name now
carries that proof: if `222.mpd.test` resolves at all, it came from VM
222's dnsmasq. `mpd-virt diag` should assert the zone apex resolves to
`10.163.<id>.4` instead.

## Implementation

### 1. Addressing module (pure refactor, no behavior change)

`mpd.test` appears as a bare literal in ~67 Swift lines across 17
files, ~35 asset lines, and ~24 setup-script lines; `10.163.0` is
similarly scattered. Land a single addressing type first, with today's
values, and route every call site through it:

```
Mpd.Net.vmId          // from Mpd.VM.Platform, cached per process
Mpd.Net.zone          // "222.mpd.test"
Mpd.Net.subnet        // "10.163.222.0/24"
Mpd.Net.gateway       // "10.163.222.1"
Mpd.Net.ip(_ host: Int)   // 3 → "10.163.222.3"
Mpd.Net.host(_ name: String)  // "php.runtime" → "php.runtime.222.mpd.test"
```

This is worth doing on its own merits and makes the eventual Go port a
one-module translation instead of 120 chances to fluff a string.

### 2. Swift call sites

- `mpd/Mpd.swift:40-52` — `internalSubnet` and the address-layout
  comment become computed.
- `mpd/Service/Service{Dnsmasq,Portal,Adminer,FileAccess}.swift` —
  the `ip:` and `dns:`/`dnsAliases:` fields in each `ServiceDescriptor`
  become computed rather than literal. `Mpd.swift:163` (`"\(name).service.mpd.test"`)
  becomes `Mpd.Net.host("\(name).service")`.
- `mpd/Service/ServiceDnsmasq.swift:167-216` — `services.conf` apex
  special-case switches from `mpd.test` to the zone apex;
  `databases.conf` uses `<db>.db.<zone>`; drop the
  `vm.service.mpd.test` block.
- `mpd/Runtime/Runtime.swift:145,340` — runtime record becomes
  `address=/<rt>.runtime.<zone>/<ip>`.
- `mpd/Runtime/DB.swift:30-56` — `allocateIP` hardcodes
  `parts[1] == "163", parts[2] == "0"` when scanning used slots; the
  third octet must compare against the VM's.
- `mpd/Action/ActionSetup.swift:428-435` — network create already uses
  `Mpd.internalSubnet`, so it follows for free.
- `mpd/VM/DNS.swift:49-64` — `DNS=` uses the computed dnsmasq IP
  (already does, via `Mpd.Service.Dnsmasq.ip`).
- `mpd/Runtime/ProjectHelpers.swift:195-205` — `mpdHosts(from:)`
  filters `host == "mpd.test" || host.hasSuffix(".mpd.test")`. The
  suffix arm already matches `moodle45.222.mpd.test`; tighten it to the
  VM's own zone so a stray foreign-VM URL in `urls.json` is not
  silently given a local cert and DNS record.

### 3. Assets

- `assets/runtimes/{php,node,util}/configuration.json` pin absolute IPs
  (`10.163.0.100`, `.101`, `.102`). Change the schema to a host octet
  (`"ipOctet": 100`) and compose in Swift.
- `assets/services/dnsmasq/dnsmasq.conf` — unchanged (see above).
- Project-type templates that hardcode `<project>.mpd.test` need the
  zone injected from the layered env — a new `MPD_ZONE` variable
  exported by `assets/runtime-base/lib/source-mpd-env.sh` is the
  natural carrier. Affects `.../moodle/mpd-template.env`,
  `.../moodle/configuration.json`, `.../moodle/scripts/configure.sh`,
  `.../moodle/templates/config-mpd-generated.php`,
  `.../moodle/tools/behat*`, `.../astro/scripts/configure.sh`,
  `.../cftunnel/*`, `assets/sidecars/caddy/gen-caddyfile.sh`, and
  `assets/services/portal/{apache.conf,www/index.php,www/diag.php}`.

### 4. Certificates

No CA change. The name constraint is `permitted;DNS.0 = .mpd.test`
(`mpd/VM/Certificate.swift:32-36`), which already permits arbitrary
depth beneath `mpd.test`. One CA continues to cover every VM.

- Service cert: `sans: ["mpd.test"]` → `[Mpd.Net.zone]`
  (`mpd/Action/ActionSetup.swift:400-406`).
- Per-project certs derive SANs from `mpdHosts(from:)` and already
  detect drift via the `cert.sans` signature file
  (`mpd/Runtime/ProjectHelpers.swift:248-260,312-316`), so they
  regenerate on their own.

### 5. Host side (`mpd-virt`, separate repo)

Lockstep, cannot ship independently. Full detail in that repo's
`docs/proposals/per-vm-addressing-and-wireguard-removal.md`; the
summary:

- **WireGuard is removed entirely.** macOS allows one active tunnel at
  a time (`WireGuard.swift:128-130` relies on this), so it can never
  deliver concurrent VMs — and it contends with the developer's
  employer VPN for the single slot. Reachability becomes a persistent
  static route per VM, `10.163.<id>.0/24 → <VM LAN IP>`, installed
  once via a LaunchDaemon. `Diag.swift:245-247` already prints this as
  option A, "simplest, no WireGuard".
- `/etc/resolver/mpd.test` → `/etc/resolver/<id>.mpd.test`.
- SSH config generation → `php.runtime.<id>.mpd.test`.
- `diag` → assert `<id>.mpd.test` resolves to `10.163.<id>.4`; the
  wrong-VM detection machinery is deleted as unreachable.

Same three facts as before, now VM-scoped — matching the
transport-agnostic client contract in `docs/ROADMAP.md`: a route to
this VM's `/24`, this VM's zone resolves, the CA is trusted. A scoped
static route to `10.163.222.0/24` coexists cleanly with a work VPN in
a way that fighting over `10.163.0.0/24` — or over the host's single
WireGuard tunnel slot — never could.

### 6. WireGuard removal, in-VM half — **done**

Owned by this repo. Landed ahead of the rest of this proposal as a
standalone first step (nothing here depends on per-VM addressing):

- Delete `bootstrap/60-wireguard.sh`; drop `wireguard` from
  `bootstrap/40-install-software.sh`; `wg-quick@mpd0` and
  `/var/lib/mpd/conf/wireguard/` go away.
- **Move `net.ipv4.ip_forward=1` first.** It is currently set *by*
  `60-wireguard.sh` and gated on the WireGuard conf existing
  (`60-wireguard.sh:36-39` — absent conf, clean no-op). Static routing
  needs that forwarding exactly as much as the tunnel did, so deleting
  the script without relocating the sysctl drop-in makes every
  container unreachable on every managed VM. It belongs in
  `bootstrap/30-networking.sh` or its own step.
- Note this also explains why a managed VM that never had a conf
  pushed has no forwarding at all today.
- `setup/linux/lib/create-vm.sh:441-443` and
  `setup/windows/lib/create-vm.ps1:218-220` only *invoke*
  `60-wireguard.sh`, which no-ops there because no conf is ever
  pushed. Both platforms already reach containers via a static route
  plus a scoped resolver entry
  (`setup/linux/lib/configure-client.sh`,
  `setup/windows/lib/configure-client.ps1`). The model this proposal
  adopts for macOS is therefore already the shipping model on two of
  three host platforms — macOS is the outlier, not the template.

### 7. Docs

`docs/NETWORKING.md` needs a rewrite rather than an edit — beyond the
topology diagram and the retired `vm.service` section, its account of
host-side DNS has never matched the code (see the correction above).
Also `docs/ARCHITECTURE.md`, `docs/SECURITY.md` (address map, and the
claim that access control lives at the WireGuard tunnel — it becomes
the hypervisor's host-only network), `docs/USAGE.md`, `README.md`,
`setup/*/README*`, `bootstrap/README.md`.

## Rollout

Flag day. Existing VMs are deleted and recreated rather than migrated —
no state migration path, no compatibility shim, no dual-zone period.
Ship the addressing refactor (step 1) first as a no-op change, verify
`make install` plus a full `--setup` / project create / HTTPS hit on a
throw-away VM, then flip the values.

## Non-goals

- **Portal as a management UI.** Moving the portal out of its container
  into a Go web server in the `mpd` binary — authenticated, write
  capable, exposing the CLI surface — is a separate project with its
  own security design. This proposal only needs to not block it. One
  note for whoever picks it up: bind to the bridge gateway
  (`10.163.<id>.1`), not `MPD_VM_IP`. The gateway is the VM itself,
  sits inside the already-routed `/24`, is identical on every
  hypervisor, and is unreachable from the rest of the LAN. `MPD_VM_IP`
  is hypervisor-assigned, differs per platform, and is exposed to the
  home network.
- **The Go port.** Independent of this change. Doing the addressing
  refactor in Swift first means the port has one module to translate
  carefully rather than 120 scattered literals, and a stable known-good
  behavior to diff against.

## Open questions

- Should the zone segment be the numeric ID or a user-chosen VM name
  (`parallels.mpd.test`, `proxmox.mpd.test`)? A name is friendlier, but
  the ID is already the subnet octet, so a name would need a separate
  ID→name mapping and would decouple the two halves. Recommend numeric
  for v1.
- `10.163.<id>.0/24` consumes `10.163.0.0/16` in aggregate. Worth
  documenting as reserved so nothing else claims part of it.
- Does anything on the workstation need to enumerate all VMs (a
  cross-VM `mpd-virt status`)? If so, the zone-per-VM scheme wants a
  registry on the host side; out of scope here.
