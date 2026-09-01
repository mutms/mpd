package web

// Templates live as Go string constants so a section and the type that
// feeds it read side by side. Every value is escaped by html/template.
// Each section is a named template and its own URL, refreshed by htmx
// independently.

const shellHTML = `{{define "page"}}<!doctype html>
<html lang="en">
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
{{/* The title is the VM hostname (mpd-NNN) and nothing else: it is a
     cross-repo contract. The host-side mpd-virt can curl https://<zone>/
     and parse this title to prove resolver + routing + TLS reach THIS VM,
     and to catch another VM answering for the zone. Zone goes in the
     heading, not here. */}}
<title>{{.Host}}</title>
<script src="/static/htmx.min.js"></script>
<style>
  :root {
    color-scheme: light dark;
    --fg: #111827; --dim: #6b7280; --line: #d1d5db66;
    --ok: #15803d; --okbg: #16a34a1f; --idle: #6b7280; --idlebg: #9ca3af22;
    --card: #ffffff; --bg: #f9fafb;
  }
  @media (prefers-color-scheme: dark) {
    :root { --fg: #e5e7eb; --dim: #9ca3af; --line: #37415188;
            --ok: #4ade80; --okbg: #16a34a26; --card: #111827; --bg: #0b0f19; }
  }
  * { box-sizing: border-box; }
  body { font: 15px/1.55 system-ui, -apple-system, "Segoe UI", sans-serif;
         color: var(--fg); background: var(--bg);
         margin: 0 auto; padding: 2rem 1.5rem 4rem; max-width: 70rem; }
  header { margin-bottom: 2rem; }
  h1 { font-size: 1.35rem; margin: 0; letter-spacing: -.01em; }
  h1 span { color: var(--dim); font-weight: 400; }
  .sub { color: var(--dim); margin: .2rem 0 0; font-size: .85rem; }
  section { background: var(--card); border: 1px solid var(--line);
            border-radius: 10px; padding: 1rem 1.15rem 1.15rem; margin-bottom: 1.25rem; }
  h2 { font-size: .78rem; text-transform: uppercase; letter-spacing: .07em;
       color: var(--dim); margin: 0 0 .75rem; font-weight: 600; }
  table { border-collapse: collapse; width: 100%; }
  th { text-align: left; font-size: .72rem; text-transform: uppercase;
       letter-spacing: .05em; color: var(--dim); font-weight: 600;
       padding: 0 .6rem .4rem 0; }
  td { padding: .4rem .6rem .4rem 0; border-top: 1px solid var(--line);
       vertical-align: top; }
  td.meta { color: var(--dim); font-family: ui-monospace, SFMono-Regular, monospace;
            font-size: .82rem; }
  .name { font-weight: 600; }
  .badge { display: inline-block; font-size: .72rem; padding: .05rem .5rem;
           border-radius: 999px; background: var(--idlebg); color: var(--idle); }
  .badge.on { background: var(--okbg); color: var(--ok); }
  .empty { color: var(--dim); font-size: .88rem; padding: .3rem 0; }
  .cred { user-select: all; }
  a { color: inherit; text-decoration-color: var(--line); }
  a:hover { text-decoration-color: currentColor; }
</style>

<header>
  <h1>mpd <span>— {{.Zone}}</span></h1>
  <p class="sub">{{.Host}}{{if .Version}} · mpd {{.Version}}{{end}}</p>
</header>

{{template "projects" .}}
{{template "services" .}}
{{template "databases" .}}
{{template "infra" .}}
</html>{{end}}`

const projectsHTML = `{{define "projects"}}
<section id="projects" hx-get="/section/projects" hx-trigger="every 5s" hx-swap="outerHTML">
  <h2>Projects</h2>
  {{if .Projects}}
  <table>
    <tr><th>Project</th><th>Status</th><th>Type</th>
        <th>Database</th><th>URL</th></tr>
    {{range .Projects}}
    <tr>
      <td class="name">{{.Name}}</td>
      <td><span class="badge {{if .Running}}on{{end}}">{{.Status}}</span></td>
      <td class="meta">{{.Type}}</td>
      <td class="meta">{{if .DBHost}}{{.DBHost}}<br>
          <span class="cred">{{.DBUser}} / {{.DBPass}}</span>
          {{range .Links}}<br><a href="{{.URL}}">{{.Label}}</a>{{end}}{{else}}—{{end}}</td>
      <td class="meta">{{if .URL}}<a href="{{.URL}}">{{.URL}}</a>{{else}}—{{end}}</td>
    </tr>
    {{end}}
  </table>
  {{else}}<p class="empty">No projects yet — <code>mpd init &lt;name&gt;</code>.</p>{{end}}
</section>
{{end}}`

const databasesHTML = `{{define "databases"}}
<section id="databases" hx-get="/section/databases" hx-trigger="every 5s" hx-swap="outerHTML">
  <h2>Databases</h2>
  {{if .Databases}}
  <table>
    <tr><th>Database</th><th>Engine</th><th>Status</th><th>DNS</th><th>Projects</th></tr>
    {{range .Databases}}
    <tr>
      <td class="name">{{.Name}}</td>
      <td class="meta">{{.Engine}}</td>
      <td><span class="badge {{if .Running}}on{{end}}">{{.Status}}</span></td>
      <td class="meta">{{.DNS}}</td>
      <td class="meta">{{.Projects}}</td>
    </tr>
    {{end}}
  </table>
  {{else}}<p class="empty">No database containers — one is created by <code>mpd start</code>.</p>{{end}}
</section>
{{end}}`

const infraHTML = `{{define "infra"}}
<section id="infra" hx-get="/section/infra" hx-trigger="every 5s" hx-swap="outerHTML">
  <h2>Infra</h2>
  <table>
    <tr><th>Name</th><th>Status</th><th>Access</th></tr>
    {{range .Infra}}
    <tr>
      <td class="name">{{.Name}}</td>
      <td><span class="badge {{if .Running}}on{{end}}">{{.Status}}</span></td>
      <td class="meta">{{.Access}}</td>
    </tr>
    {{end}}
  </table>
</section>
{{end}}`

const servicesHTML = `{{define "services"}}
<section id="services" hx-get="/section/services" hx-trigger="every 5s" hx-swap="outerHTML">
  <h2>Services</h2>
  <table>
    <tr><th>Service</th><th>Status</th><th>Address</th><th>Access</th></tr>
    {{range .Services}}
    <tr>
      <td class="name">{{.Name}}</td>
      <td><span class="badge {{if .Running}}on{{end}}">{{.Status}}</span></td>
      <td class="meta">{{.IP}}<br>{{.DNS}}</td>
      <td class="meta">{{if .Running}}<a href="{{.Access}}">{{.Access}}</a>{{else}}{{.Access}}{{end}}</td>
    </tr>
    {{end}}
  </table>
</section>
{{end}}`
