# Desktop Security (mpd-desktop)

This page describes security properties for `mpd-desktop` on macOS.

## Core model

`mpd` is a local single-developer environment.

- run `mpd` as non-root
- host is macOS with Podman Desktop + WireGuard app
- runtime workloads are isolated inside the Podman VM

## Network exposure

Desktop mode uses a loopback-only bootstrap endpoint:

- WireGuard bootstrap bind: `127.0.0.1:51820/udp`
- no `0.0.0.0` host exposure required for normal desktop operation
- container access flows through WireGuard tunnel only

## TLS and trust

- private CA generated under `~/Developer/mpd/conf/caroot/`
- `*.mpd.test` certificates are signed by this CA
- trust is added to macOS Keychain during setup
- CA is constrained for local `mpd.test` usage
- on a Mac that also has mpd-machine installed, `mpd --setup` adopts
  the existing CA from `~/.mpd-machine/ca/` if `caroot/` is missing
  (the macos-utm bootstrap scripts mirror to that path), so both
  modes share a single CA. CAs flow host → VM only — neither mode
  pulls a cert off a VM into the keychain. Full rule in
  [../machine/SECURITY.md §"TLS and the certificate authority"](../machine/SECURITY.md#tls-and-the-certificate-authority).

## Credentials and keys

- keep `~/Developer/mpd/conf/` private (especially `caroot/`, `wireguard/`, and `service/`)
- WireGuard tunnel config includes private material
- SSH agent forwarding is used for git auth (private keys remain in host agent)

## Important tradeoffs

- this is not a multi-tenant hardened environment
- containers share development-oriented trust assumptions
- malicious project scripts can execute inside runtime containers

## Service UI exposure model

Adminer (always-on infra service) is exposed through the portal TLS endpoint:

- `https://adminer.service.mpd.test` -> portal reverse proxy -> `mpd-service-adminer:8080`

Mailpit is no longer a global service — it runs as a per-runtime sidecar
attached to each PHP runtime pod. Each project gets its own Mailpit UI:

- `https://mail.<project>.mpd.test` -> runtime's Caddy frontdoor -> `127.0.0.1:8025` inside the runtime pod
- SMTP submission stays inside the pod on `127.0.0.1:1025`, so PHP's `mail()` reaches Mailpit without ever leaving the pod's network namespace.

Security properties:

- service and sidecar containers use unprivileged high ports (no root required for low-port bind)
- TLS termination for `*.service.mpd.test` is centralized in `mpd-service-portal`; per-project URLs (including Mailpit) terminate TLS at the runtime's Caddy frontdoor
- DNS for `*.service.mpd.test` resolves to portal (`10.163.0.4`); DNS for project hostnames resolves to the owning runtime's IP

Tradeoff:

- portal is on the availability path for Adminer UI access
- runtime Caddy frontdoor is on the availability path for project UIs (including per-project Mailpit)

## Related

- Desktop networking: [NETWORKING.md](NETWORKING.md)
- Full machine-focused security details: [../machine/SECURITY.md](../machine/SECURITY.md)
