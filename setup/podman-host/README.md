# mpd on Podman Desktop (POC)

Experimental — proving that mpd can run inside a single privileged
Podman container in place of a full Debian VM. Architecture and
motivation: [`docs/proposals/podman-host-nested.md`](../../docs/proposals/podman-host-nested.md).

**Status:** the Containerfile boots a Debian Trixie + systemd + sshd
container that the bootstrap pipeline (`bootstrap/{20..60}` + `mpd
--setup`) can run inside. Networking, WireGuard, and the host-side
route + resolver + CA trust hand-off are not yet wired — that's the
next round of work.

## Build & run

```bash
cd setup/podman-host
cp ~/.ssh/id_ed25519.pub .          # → build context
sudo podman build -t mpd-poc .
rm id_ed25519.pub                   # optional cleanup

sudo podman run -d --name mpd-poc \
    --hostname mpd-000 \
    --privileged --systemd=always \
    -p 2223:22 \
    mpd-poc

ssh -p 2223 skodak@localhost
```

`--hostname mpd-000` is set at create time because `hostnamectl
set-hostname` returns EBUSY inside Podman containers (kernel
sethostname under the container's UTS ns). Step 30 then sees
`current == target` and skips the rename.

## Bootstrap inside the container

```bash
bash <(wget -qO- https://raw.githubusercontent.com/mutms/mpd/main/bootstrap/20-git-clone.sh)
bash /opt/mpd/bootstrap/30-networking.sh 000
bash /opt/mpd/bootstrap/40-install-software.sh
bash /opt/mpd/bootstrap/50-build.sh
mpd --setup
```

Octet `000` → sandbox path: bootstrap skips the static-IP pin entirely.

## Teardown

```bash
sudo podman rm -f mpd-poc
sudo podman rmi mpd-poc             # optional
```
