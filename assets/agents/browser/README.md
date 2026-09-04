# browser — headless screenshots & DOM checks for agents

A tiny helper so an AI agent can *see* and *drive* a local web UI (e.g. the
mdl-demo console) without a real browser — take a screenshot to eyeball, or run
JS assertions against the live DOM (htmx swaps, button states, …) that a plain
`curl` can't observe.

## Why it looks the way it does

**Zero npm dependencies.** It talks to the system chromium directly over the
Chrome DevTools Protocol using only Node built-ins (the global `WebSocket`,
`child_process`, `fs`). The entire trusted surface is two short files —
`cdp.mjs` (the CDP client) and `shot.mjs` (the CLI) — meant to be read
top-to-bottom before this rides along to another VM. No lockfile to audit, no
`node_modules` supply chain, nothing fetched from the network except the page
you point it at.

## Requirements

- **chromium** at `/usr/bin/chromium` (override with `CHROMIUM=/path`).
- **Node 22+** (needs the global `WebSocket`; tested on Node 24).

## Screenshot

```sh
node /opt/mpd/assets/agents/browser/shot.mjs http://127.0.0.1:8081 out.png
```

Saves a full-page PNG; settles ~300 ms after load so late JS/htmx swaps are
captured. The agent then reads the PNG.

## Drive / assert (programmatic)

```js
import { launch, openPage } from '/opt/mpd/assets/agents/browser/cdp.mjs';

const browser = await launch();
try {
  const page = await openPage(browser.conn, 'http://127.0.0.1:8081');
  const tabs = await page.eval(`[...document.querySelectorAll('.tab')].map(e => e.textContent.trim())`);
  await page.eval(`document.querySelector('.pkg input[name="recipe"]').click()`);
  const btn = await page.eval(`document.querySelector('button.install').textContent.trim()`);
  console.log({ tabs, btn });          // e.g. { tabs: ['Moodle','MuTMS'], btn: 'Install Moodle 5.2.2' }
  await page.screenshot('out.png');
} finally {
  await browser.close();
}
```

`page.eval(expr)` runs JS in the page and returns a JSON-able value (throws on a
page error); `page.screenshot(path)` writes a PNG.

## Environment

| var        | default             | meaning                                            |
| ---------- | ------------------- | -------------------------------------------------- |
| `CHROMIUM` | `/usr/bin/chromium` | browser binary                                     |
| `SANDBOX`  | *(off)*             | `SANDBOX=1` keeps chromium's sandbox               |

`--no-sandbox` is the default because this drives **trusted local pages** in a
disposable dev VM; set `SANDBOX=1` for anything less trusted. Each run uses a
throwaway `--user-data-dir` that is removed on exit, and chromium's debug port
stays bound to loopback with an unguessable path.
