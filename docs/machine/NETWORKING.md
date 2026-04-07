# Machine Networking (mpd-machine)

How the host laptop reaches mpd's container subnet inside the VM.

Status: this is what `mpd --setup` produces on Machine. Per-OS laptop-side
recipes (route, resolver, optional CA trust) are printed at the end of
setup. Persistence of those laptop-side bits is OS-specific (see "Per-OS
client recipes" below).

## Topology

```text
Laptop (macOS / Linux / Windows)
  |
  | LAN  (e.g. 192.168.x / UTM bridge 192.168.64.x)
  |
VM host (Debian Trixie)         hostname: mpd-machine
  |
  Podman (rootful) bridge:  podman1  10.163.0.1/24
   |
   `mpd-internal` Podman network    10.163.0.0/24
     |
     +-- mpd-service-dnsmasq     10.163.0.3   (DNS for *.mpd.test)
     +-- mpd-service-portal      10.163.0.4   (HTTPS read-only status)
     +-- mpd-service-fileaccess  10.163.0.5   (data-volume podman-exec target;
     |                                          SSH/scp endpoint for /srv/backups/)
     +-- mpd-service-adminer     10.163.0.6   (proxied via portal)
     +-- DB containers           10.163.0.30–.99
     +-- runtime containers      10.163.0.100+ (full dev access via SSH)
```

The VM runs `net.ipv4.ip_forward=1` so packets from the laptop transit
the VM and reach containers via `podman1`.

## How the laptop reaches containers

mpd-machine uses **plain static routing** from the laptop into the VM. There
is no WireGuard tunnel. The laptop adds:

1. A static route for `10.163.0.0/24` via the VM's LAN IP.
2. A DNS resolver entry pointing `*.mpd.test` queries at `10.163.0.3`
   (the dnsmasq container).
3. (Optional) The mpd CA installed in the system trust store. Skip and
   accept per-site browser warnings if you prefer.

`mpd --setup` prints OS-specific recipes for all three (macOS, Debian/Ubuntu,
Fedora/RHEL, Windows) at the end of its run.

### Why no WireGuard

mpd-desktop uses WireGuard because the macOS host has no other route into
its Podman machine VM. On mpd-machine the laptop is *outside* the UTM VM
but on the same trust boundary (single user, home LAN), and the VM's host
IP is directly routable — so plain L3 routing handles it natively.

Removing WG drops a stack of pain: kernel module loading, key rotation,
and client app installation.

## Per-OS client recipes (printed by `mpd --setup`)

### macOS

```
sudo route -n add -net 10.163.0.0/24 192.168.64.158
echo "nameserver 10.163.0.3" | sudo tee /etc/resolver/mpd.test >/dev/null
# Optional CA trust for clean HTTPS:
sudo security add-trusted-cert -d -r trustRoot \
  -k /Library/Keychains/System.keychain mpd-rootCA.pem
```

macOS does not persist routes across reboots — re-add after reboot, or wrap
in a LaunchDaemon plist. The route is also wiped when an mpd-desktop
WireGuard tunnel is brought up and then back down: while WG is up it owns
its own route to `10.163.0.0/24` via `utun*`, and bringing WG down removes
that route without restoring any earlier static route. Re-add the static
route any time you switch from WG-based mpd-desktop back to mpd-machine.

### Linux (Debian/Ubuntu/Fedora/RHEL)

```
sudo ip route add 10.163.0.0/24 via <vm-ip>
sudo install -D -m 644 /dev/stdin /etc/systemd/resolved.conf.d/mpd.conf <<'EOF'
[Resolve]
DNS=10.163.0.3
Domains=~mpd.test
EOF
sudo systemctl restart systemd-resolved
```

For persistence: NetworkManager `nmcli connection modify <conn> +ipv4.routes`,
or systemd-networkd config.

### Windows (admin)

```
route add 10.163.0.0 mask 255.255.255.0 <vm-ip> -p
Add-DnsClientNrptRule -Namespace ".mpd.test" -NameServers "10.163.0.3"
```

The `-p` flag persists the route across reboots.

## Coexistence with mpd-desktop

If both `mpd-desktop` (WG-based) and `mpd-machine` (route-based) are present
on the same Mac, both target `10.163.0.0/24`. macOS picks one path at a time
based on route precedence:

- Desktop WG tunnel ON: WG.app's `utun` route wins, traffic goes through the
  Desktop tunnel.
- Desktop WG tunnel OFF: the static route to the Machine VM is active *if
  it's currently in the routing table*. WG doesn't restore the static
  route when it disconnects — it just removes its own — so after toggling
  WG you usually need to `sudo route -n add ...` again.

They don't conflict catastrophically — they share by precedence. You cannot
use both simultaneously (same subnet has one path at a time), but for most
workflows that's not a real limitation.

## DNS forwarding upstream

dnsmasq inside the container sets `local=/mpd.test/` (so it's authoritative
for `*.mpd.test` and never forwards those queries) and reads upstream
resolvers from a bind-mounted view of the host's
`/run/systemd/resolve/resolv.conf` — the *real* per-link upstream nameservers
managed by systemd-resolved, **not** the `127.0.0.53` stub that
`/etc/resolv.conf` points at. dnsmasq watches that file and adapts when the
host switches networks (corporate VPN, Wi-Fi, etc.) without restart.

There is no `MPD_DNS_UPSTREAM` to configure and no hardcoded public DNS in
the path: queries follow whatever the host's link manager (NetworkManager
or systemd-networkd) hands to systemd-resolved. On a corporate VPN that's
the corporate DNS; on a home network it's the router; on a coffee-shop
Wi-Fi it's whatever the AP gave you. Same chain whether a laptop client
routes all DNS through dnsmasq or only `*.mpd.test`.

## DNS authoritativeness

dnsmasq is **authoritative** for `*.mpd.test`. Unknown names in that domain
return NXDOMAIN immediately, AAAA queries on names with only A records
return NoData. This avoids the upstream-forwarding stalls that previously
caused multi-second `getaddrinfo` delays when AAAA queries leaked to public
DNS for `.test` TLD names.

## SSH access to runtime containers

Use jump-host SSH to keep zero laptop-side networking complexity:

```
# ~/.ssh/config:
Host *.runtime.mpd.test
    ProxyJump <vm-ip>
```

The second-hop hostname resolves on the **first hop** (the VM), where
dnsmasq works. IDEs (PHPStorm, VS Code Remote-SSH) configure ProxyJump
the same way.

mpd assumes your laptop user, VM user, and runtime user share the same
name — that's what makes the bare `<vm-ip>` form work without explicit
`user@`. Set up the VM with the same account name as your laptop login.

## Future direction

Two improvements considered, neither mandatory:

- **Optional VNC-browser service container** — a containerized headless
  browser + VNC/noVNC, port-published on the VM host. Laptop accesses
  `http://<vm-ip>:7900/` and gets a remote browser that already lives on
  `mpd-internal` — no laptop-side route or DNS needed for browser-only
  workflows.
- **GNOME-in-VM** — install a desktop environment inside the VM and
  run everything (browser, IDE, terminal) inside the UTM display
  window. QEMU+SPICE gives clipboard sharing, dynamic resize, audio,
  and USB redirection.

See also: [README.md](README.md), [SECURITY.md](SECURITY.md)
