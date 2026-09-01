# Vendored front-end assets

Committed rather than fetched, and served from the mpd binary itself
(`go:embed`), for the same reason nothing else here reaches a CDN: the
portal has to render on a VM with no internet, and a status page that
depends on a third party being up is not a status page.

Pinned and checksummed like the other third-party artefacts mpd ships —
see `assets/services/adminer/Containerfile` (`ADMINER_VERSION`) and
`assets/vm/bin/composer-install`.

| File          | Version | Source                                                        | License |
|---------------|---------|---------------------------------------------------------------|---------|
| `htmx.min.js` | 2.0.10  | `https://cdn.jsdelivr.net/npm/htmx.org@2.0.10/dist/htmx.min.js` | 0BSD    |

```
sha256  71ea67185bfa8c98c39d31717c6fce5d852370fcdfd129db4543774d3145c0de
size    51238
```

0BSD imposes no conditions, so there is nothing to reproduce in mpd's
own GPL-3 distribution; this file records provenance, not obligation.

## Updating

```sh
cd go/internal/web/static
curl -fsSL -o htmx.min.js https://cdn.jsdelivr.net/npm/htmx.org@<version>/dist/htmx.min.js
sha256sum htmx.min.js          # update the table above
```

Then re-check the page: htmx is the only thing driving partial refresh,
so a bad upgrade shows up as sections that stop updating rather than as
a build failure.
