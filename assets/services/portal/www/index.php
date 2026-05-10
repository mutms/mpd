<?php
// mpd portal — served at https://mpd.test/ by mpd-service-portal (debian:trixie + apache2 + php)
// SECURITY: This page is READ-ONLY. It displays status information only.
// Do NOT add any command execution, form handling, API endpoints, or user input processing.
//
// Data sources (all bind-mounted read-only from the host machine dir):
// - /mpd-state/current-state.json — live observation snapshot, refreshed
//   on `mpd list` / `mpd --status` / `mpd --start` / state-mutating verbs.
//   Authoritative for `current` (running / stopped / missing) of runtimes,
//   projects, and DB containers.
// - /mpd-state/projects.json — persisted project intent (`requested`).
//   Source of project metadata (type, runtime, DB engine + version, urls).
// - /mpd-state/runtimes/<n>/meta.json — persisted runtime intent + IP.
// - /mpd-state/databases.json — DB container metadata cache (engine,
//   version, containerName) used to resolve databaseId → engine.
// - /srv/meta/<project>/project.json — ground-truth project identity
//   (mpd-managed; read-only here).
// - /mnt/assets/runtimes — list of available runtime templates.

function h(string $s): string {
    return htmlspecialchars($s, ENT_QUOTES, 'UTF-8');
}

/**
 * Display name for the portal heading + title. Written by Swift's
 * Mpd.Service.Portal.setup() to /mpd-state/portal/display-name.txt:
 *   • mpd-machine: VM hostname (e.g. "mpd-machine-158")
 *   • mpd-desktop: machineName (e.g. "mpd-desktop" or "mpd-desktop-foo")
 * Falls back to "mpd" if the file is missing (older setups, transient
 * read errors).
 */
function displayName(): string {
    $path = '/mpd-state/portal/display-name.txt';
    if (is_readable($path)) {
        $name = trim((string)@file_get_contents($path));
        if ($name !== '') return $name;
    }
    return 'mpd';
}

/**
 * Dev user for SSH-based IDE links (vscode://, jetbrains-gateway://).
 * Written by Mpd.Service.Portal.setup() — matches the runtime container's
 * dev user (host UID/username). Falls back to "user" so we always render
 * something clickable; the user fixes their SSH config if it's wrong.
 */
function devUser(): string {
    $path = '/mpd-state/portal/dev-user.txt';
    if (is_readable($path)) {
        $name = trim((string)@file_get_contents($path));
        if ($name !== '') return $name;
    }
    return 'user';
}

/**
 * Read a project type's `ideLinks` flag from
 * /mnt/assets/runtimes/*&#47;project_types/<type>/configuration.json.
 * Default true (matches Swift's ProjectTypeConfiguration default).
 * Cached per type — config files don't change inside a request.
 */
function projectTypeAllowsIdeLinks(string $type): bool {
    static $cache = [];
    if (isset($cache[$type])) return $cache[$type];
    if ($type === '') return $cache[$type] = false;
    $matches = glob("/mnt/assets/runtimes/*/project_types/{$type}/configuration.json") ?: [];
    if (empty($matches)) return $cache[$type] = true;
    $data = json_decode((string)@file_get_contents($matches[0]), true);
    if (!is_array($data)) return $cache[$type] = true;
    return $cache[$type] = !(isset($data['ideLinks']) && $data['ideLinks'] === false);
}

/**
 * Cheap state hash — md5 of name+mtime+size for every file the portal reads.
 * Used by the client to detect changes without re-rendering the full page,
 * so an open popover survives idle polling.
 */
function stateHash(): string {
    $sources = array_merge(
        glob('/srv/meta/*/project.json') ?: [],
        glob('/srv/meta/*/urls.json') ?: [],
        glob('/mpd-state/runtimes/*/meta.json') ?: [],
        ['/mpd-state/projects.json', '/mpd-state/databases.json', '/mpd-state/current-state.json']
    );
    sort($sources);
    $sig = '';
    foreach ($sources as $f) {
        $stat = @stat($f);
        $sig .= $stat ? "{$f}|{$stat['mtime']}|{$stat['size']}|" : "{$f}|-|";
    }
    return md5($sig);
}

// Poll endpoint: return just the hash, no HTML. Plain text, cheap.
if (isset($_GET['hash'])) {
    header('Content-Type: text/plain');
    header('Cache-Control: no-store');
    echo stateHash();
    exit;
}

/**
 * Pick the "main" URL for a project from its urls list. Prefers the entry whose
 * kind is "web" or whose label is "main"; otherwise the first URL; otherwise ''.
 */
function pickMainUrl(array $urls): string {
    foreach ($urls as $u) {
        if (!is_array($u)) continue;
        if (($u['kind'] ?? '') === 'web' || ($u['label'] ?? '') === 'main') {
            return (string)($u['url'] ?? '');
        }
    }
    return isset($urls[0]['url']) ? (string)$urls[0]['url'] : '';
}

/**
 * Map a project name to a CSS-safe ident for popover anchor-name / popovertarget.
 * mpd project names are lowercase alphanumerics so this is mostly defensive.
 */
function popoverIdFor(string $project): string {
    $clean = preg_replace('/[^a-z0-9-]/', '', strtolower($project));
    return "proj-{$clean}";
}

function collectAvailableRuntimeNames(string $assetsRuntimesDir): array {
    $names = [];
    if (!is_dir($assetsRuntimesDir)) return $names;
    foreach (scandir($assetsRuntimesDir) as $dir) {
        if ($dir === '.' || $dir === '..') continue;
        if (is_dir("{$assetsRuntimesDir}/{$dir}")) {
            $names[$dir] = true;
        }
    }
    $result = array_keys($names);
    sort($result);
    return $result;
}

/**
 * Load the live-state snapshot written by mpd. Source-of-truth for
 * `current` status of runtimes, projects, and DBs. Each map is
 * name → "running" / "stopped" / "missing".
 *
 * Refreshed by `mpd list`, `mpd --status`, `mpd --start`, `mpd --setup`,
 * and the state-mutating verbs. Falls back to an empty snapshot if
 * the file is missing — older mpd versions or fresh setups before any
 * refresh has run.
 */
function loadCurrentState(string $file): array {
    $defaults = ['runtimes' => [], 'projects' => [], 'databases' => [], 'refreshedAt' => ''];
    if (!is_readable($file)) return $defaults;
    $raw = json_decode(file_get_contents($file), true);
    if (!is_array($raw)) return $defaults;
    return [
        'runtimes' => is_array($raw['runtimes'] ?? null) ? $raw['runtimes'] : [],
        'projects' => is_array($raw['projects'] ?? null) ? $raw['projects'] : [],
        'databases' => is_array($raw['databases'] ?? null) ? $raw['databases'] : [],
        'refreshedAt' => (string)($raw['refreshedAt'] ?? ''),
    ];
}

function loadDatabaseStateCache(string $databasesFile): array {
    if (!is_readable($databasesFile)) return [];

    $raw = json_decode(file_get_contents($databasesFile), true);
    if (!is_array($raw['databases'] ?? null)) return [];

    $dbs = [];
    foreach ($raw['databases'] as $db) {
        if (!is_array($db)) continue;
        $databaseId = (string)($db['databaseId'] ?? '');
        $engine = (string)($db['engine'] ?? '');
        $version = (string)($db['version'] ?? '');
        if ($databaseId === '' || $engine === '' || $version === '') continue;

        $status = (string)($db['status'] ?? 'stopped');
        if ($status !== 'running' && $status !== 'stopped') {
            $status = 'stopped';
        }

        $dbs[$databaseId] = [
            'engine' => $engine,
            'version' => $version,
            'databaseId' => $databaseId,
            'containerName' => (string)($db['containerName'] ?? ''),
            'projects' => [],
            'status' => $status,
        ];
    }

    ksort($dbs);
    return $dbs;
}

function ipSortValue(string $ip): int {
    $parts = array_map('intval', explode('.', $ip));
    if (count($parts) !== 4) return PHP_INT_MAX;
    return ($parts[0] << 24) + ($parts[1] << 16) + ($parts[2] << 8) + $parts[3];
}

function tcpProbe(string $host, int $port, float $timeoutSeconds = 0.20): bool {
    $errno = 0;
    $errstr = '';
    $sock = @fsockopen($host, $port, $errno, $errstr, $timeoutSeconds);
    if ($sock === false) return false;
    fclose($sock);
    return true;
}

// --- Load live-state snapshot (current-state.json) ---
// Source-of-truth for `current` status of runtimes/projects/DBs.
// Refreshed on `mpd list` / `mpd --status` / `mpd --start` / mutating verbs.
$currentState = loadCurrentState('/mpd-state/current-state.json');

// --- Load project records (projects.json — persisted intent + metadata) ---
$projects = [];
$projectsFile = '/mpd-state/projects.json';
if (is_readable($projectsFile)) {
    $data = json_decode(file_get_contents($projectsFile), true);
    if (is_array($data['projects'] ?? null)) {
        foreach ($data['projects'] as $p) {
            $name = $p['name'] ?? '';
            if ($name !== '') {
                // Inject `current` from the live snapshot. Fall back to
                // 'not-configured' if neither source provides one.
                $p['status'] = $currentState['projects'][$name]
                    ?? (string)($p['status'] ?? 'not-configured');
                $projects[$name] = $p;
            }
        }
    }
}

// --- Enrich project data from /srv/meta/ (ground truth) ---
$metaDir = '/srv/meta';
if (is_dir($metaDir)) {
    foreach (scandir($metaDir) as $dir) {
        if ($dir === '.' || $dir === '..') continue;
        $pjFile = "{$metaDir}/{$dir}/project.json";
        if (!is_readable($pjFile)) continue;
        $meta = json_decode(file_get_contents($pjFile), true);
        if (!is_array($meta)) continue;
        $name = $meta['name'] ?? $dir;

        $metaUrls = is_array($meta['urls'] ?? null) ? $meta['urls'] : [];
        if (isset($projects[$name])) {
            $projects[$name]['type'] = $meta['type'] ?? $projects[$name]['type'] ?? 'unknown';
            $projects[$name]['databaseEngine'] = $meta['databaseEngine'] ?? $projects[$name]['databaseEngine'] ?? '';
            $projects[$name]['databaseVersion'] = $meta['databaseVersion'] ?? $projects[$name]['databaseVersion'] ?? '';
            $projects[$name]['databaseId'] = $meta['databaseId'] ?? $projects[$name]['databaseId'] ?? '';
            // /srv/meta is ground truth; prefer its urls list when present.
            if (!empty($metaUrls) || !isset($projects[$name]['urls'])) {
                $projects[$name]['urls'] = $metaUrls;
            }
        } else {
            $projects[$name] = [
                'name' => $name,
                'type' => $meta['type'] ?? 'unknown',
                'databaseEngine' => $meta['databaseEngine'] ?? '',
                'databaseVersion' => $meta['databaseVersion'] ?? '',
                'databaseId' => $meta['databaseId'] ?? '',
                'runtimeName' => '',
                'status' => 'not-configured',
                'urls' => $metaUrls,
            ];
        }
    }
}
ksort($projects);

// --- Group projects by runtimeName ---
$projectsByRuntime = [];
foreach ($projects as $p) {
    $rt = $p['runtimeName'] ?? '';
    if ($rt !== '') {
        $projectsByRuntime[$rt][] = $p;
    }
}

// --- Load created runtime metadata from /mpd-state/runtimes ---
$createdRuntimes = [];
$runtimesDir = '/mpd-state/runtimes';
if (is_dir($runtimesDir)) {
    foreach (scandir($runtimesDir) as $dir) {
        if ($dir === '.' || $dir === '..') continue;
        $metaFile = "{$runtimesDir}/{$dir}/meta.json";
        if (!is_readable($metaFile)) continue;
        $meta = json_decode(file_get_contents($metaFile), true);
        if (!is_array($meta)) continue;
        $name = $meta['name'] ?? $dir;
        $createdRuntimes[$name] = $meta;
    }
}

// --- Merge with available runtime names from assets ---
$availableRuntimeNames = collectAvailableRuntimeNames('/mnt/assets/runtimes');
$allRuntimeNames = [];
foreach ($availableRuntimeNames as $n) { $allRuntimeNames[$n] = true; }
foreach (array_keys($createdRuntimes) as $n) { $allRuntimeNames[$n] = true; }
$allRuntimeNames = array_keys($allRuntimeNames);
sort($allRuntimeNames);

$runtimes = [];
foreach ($allRuntimeNames as $name) {
    $created = $createdRuntimes[$name] ?? null;

    // Live status comes from the current-state snapshot. Mapping:
    //   "running"  → "running"
    //   "stopped"  → "stopped"
    //   "missing"  → "available" (no container exists)
    //   (absent)   → "available" if no record, else "stopped"
    $liveStatus = $currentState['runtimes'][$name] ?? '';
    if ($liveStatus === 'missing') $liveStatus = 'available';
    if ($liveStatus === 'running' || $liveStatus === 'stopped' || $liveStatus === 'available') {
        $status = $liveStatus;
    } else if ($created !== null) {
        $status = 'stopped';
    } else {
        $status = 'available';
    }

    // Runtime DNS hostname is the SSH target — there's no HTTPS service on
    // *.runtime.mpd.test, so the hostname renders as plain text (not a link).
    $runtimeDns = ($status === 'running') ? "{$name}.runtime.mpd.test" : '—';

    $runtimes[$name] = [
        'name' => $name,
        'ip' => $created['ip'] ?? '—',
        'status' => $status,
        'dns' => $runtimeDns,
        'projectCount' => count($projectsByRuntime[$name] ?? []),
    ];
}

// --- Databases from machine cache (/mpd-state/databases.json), with project counts ---
$databases = loadDatabaseStateCache('/mpd-state/databases.json');
// Layer fresher live status from current-state.json on top — databases.json
// is only rebuilt on `mpd --setup` / `mpd list dbs` / db verbs; the live
// snapshot refreshes on every `mpd list` and is more up-to-date.
foreach ($databases as $dbId => &$db) {
    $live = $currentState['databases'][$dbId] ?? '';
    if ($live === 'running' || $live === 'stopped') {
        $db['status'] = $live;
    }
}
unset($db);
foreach ($projects as $p) {
    $engine = (string)($p['databaseEngine'] ?? '');
    $version = (string)($p['databaseVersion'] ?? '');
    if ($engine === '' || $version === '') continue;

    $dbId = (string)($p['databaseId'] ?? '');
    if ($dbId === '') {
        $dbId = $engine . '-' . str_replace('.', '-', $version);
    }

    if (!isset($databases[$dbId])) continue;

    $projectName = (string)($p['name'] ?? '');
    if ($projectName !== '' && !in_array($projectName, $databases[$dbId]['projects'], true)) {
        $databases[$dbId]['projects'][] = $projectName;
    }
}
ksort($databases);

// --- Services (always-on infra containers, IPs match Mpd.Service.*).
// `mailpit`, `valkey`, `selenium` are NOT services — they're per-runtime
// sidecars attached to the runtime pod (see Mpd.Runtime.Sidecars). Their
// status follows the runtime, not a global service descriptor.
$services = [
    ['name' => 'dnsmasq',    'ip' => '10.163.0.3', 'dns' => 'dnsmasq.service.mpd.test',    'access' => 'DNS resolver (10.163.0.3:53)', 'probePort' => 53],
    ['name' => 'portal',     'ip' => '10.163.0.4', 'dns' => 'mpd.test',                     'access' => 'https://mpd.test/', 'probePort' => 443],
    ['name' => 'fileaccess', 'ip' => '10.163.0.5', 'dns' => 'fileaccess.service.mpd.test', 'access' => 'ssh user@fileaccess.service.mpd.test (volume tool / backups)', 'probePort' => 22],
    ['name' => 'adminer',    'ip' => '10.163.0.6', 'dns' => 'adminer.service.mpd.test',    'access' => 'https://adminer.service.mpd.test/', 'probePort' => 8080],
];

foreach ($services as $idx => $svc) {
    if ($svc['name'] === 'portal') {
        // Self-probe: if this PHP is rendering, portal is up.
        $services[$idx]['status'] = 'running';
    } else if ($svc['probePort'] === null) {
        $services[$idx]['status'] = 'unknown';
    } else {
        $services[$idx]['status'] = tcpProbe($svc['ip'], (int)$svc['probePort']) ? 'running' : 'stopped';
    }
}

usort($services, function ($a, $b) {
    return ipSortValue($a['ip']) <=> ipSortValue($b['ip']);
});

$adminerRunning = false;
foreach ($services as $svc) {
    if (($svc['name'] ?? '') === 'adminer' && ($svc['status'] ?? '') === 'running') {
        $adminerRunning = true;
        break;
    }
}
?>
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="utf-8">
    <title><?= h(displayName()) ?></title>
    <style>
        * { box-sizing: border-box; }
        body {
            font-family: ui-monospace, 'Cascadia Code', monospace;
            background: #fff;
            color: #222;
            margin: 0;
            padding: 2rem;
        }
        h1 { font-size: 2rem; font-weight: 700; margin: 0 0 2rem; color: #111; letter-spacing: -0.01em; }
        h2 { font-size: 0.85rem; color: #999; margin: 1.5rem 0 0.5rem; text-transform: uppercase; letter-spacing: 0.06em; }
        table { border-collapse: collapse; }
        td { padding: 0.25rem 1.5rem 0.25rem 0; vertical-align: top; }
        a { color: #0066cc; text-decoration: none; }
        a:hover { text-decoration: underline; }
        .status { display: inline-block; width: 0.5rem; height: 0.5rem; border-radius: 50%; margin-right: 0.4rem; }
        .status-running { background: #22c55e; }
        .status-stopped { background: #f59e0b; }
        .status-available { background: #aaa; }
        .status-unknown { background: #bbb; }
        .meta { color: #888; font-size: 0.9rem; }
        .note { color: #999; font-size: 0.75rem; }
        .none { color: #999; }

        /* "details" button inside the projects table — same shape as
           other tables on this page; just the button cell needs styling. */
        .expand {
            background: #f8f8f8;
            border: 1px solid #ccc;
            border-radius: 4px;
            cursor: pointer;
            padding: 0.1rem 0.6rem;
            color: #555;
            font: inherit;
            font-size: 0.8rem;
        }
        .expand:hover { background: #eaeaea; border-color: #999; color: #222; }

        [popover] {
            position: absolute;
            inset: auto;
            margin: 0;
            border: 1px solid #ddd;
            border-radius: 6px;
            padding: 0.9rem 1.1rem;
            background: #fff;
            box-shadow: 0 6px 24px rgba(0,0,0,0.12);
            min-width: 24rem;
            max-width: 38rem;
            /* Anchor is the trigger button (anchor-name on .expand). Position
               below the button, aligned to its right edge so the popover
               opens tight under it rather than spanning the whole row. */
            position-area: bottom span-left;
            margin-top: 0.25rem;
        }
        .popover h3 { margin: 0 0 0.6rem; font-size: 0.95rem; color: #333; }
        .popover h4 {
            margin: 0.9rem 0 0.4rem;
            font-size: 0.7rem;
            color: #999;
            text-transform: uppercase;
            letter-spacing: 0.06em;
            font-weight: normal;
        }
        .popover .props {
            display: grid;
            grid-template-columns: 5.5rem 1fr;
            gap: 0.2rem 0.75rem;
            margin: 0;
            font-size: 0.85rem;
        }
        .popover .props dt { color: #999; }
        .popover .props dd { margin: 0; color: #333; }
        .popover .urls {
            list-style: none;
            padding: 0;
            margin: 0;
            display: flex;
            flex-direction: column;
            gap: 0.3rem;
            font-size: 0.85rem;
        }
        .popover .urls li {
            display: flex;
            align-items: center;
            gap: 0.6rem;
        }
        .kind-badge {
            display: inline-block;
            font-size: 0.7rem;
            padding: 0.05rem 0.45rem;
            border-radius: 3px;
            background: #e5e7eb;
            color: #444;
            text-transform: lowercase;
            letter-spacing: 0.02em;
            min-width: 4rem;
            text-align: center;
            font-weight: 500;
        }
        .kind-web     { background: #dbeafe; color: #1e3a8a; }
        .kind-behat   { background: #fef3c7; color: #92400e; }
        .kind-mail    { background: #d1fae5; color: #065f46; }
        .kind-devport { background: #fce7f3; color: #9d174d; }
        .kind-ide     { background: #ede9fe; color: #5b21b6; }
    </style>
</head>
<body>
<h1><?= h(displayName()) ?></h1>

<h2>Projects</h2>
<?php if (empty($projects)): ?>
    <p class="none">No projects found.</p>
<?php else: ?>
<table>
<tr>
    <td class="meta">name</td>
    <td class="meta">status</td>
    <td class="meta">url</td>
    <td class="meta">details</td>
</tr>
<?php foreach ($projects as $p):
    $pName = (string)($p['name'] ?? '');
    $pStatus = (string)($p['status'] ?? 'not-configured');
    $pRuntime = (string)($p['runtimeName'] ?? '');
    $pType = (string)($p['type'] ?? 'unknown');
    $pUrls = is_array($p['urls'] ?? null) ? $p['urls'] : [];
    $statusClass = ($pStatus === 'running') ? 'running' : (($pStatus === 'stopped') ? 'stopped' : 'available');
    $running = ($pStatus === 'running');
    $mainUrl = pickMainUrl($pUrls);
    $popoverId = popoverIdFor($pName);

    $pDbEngine = (string)($p['databaseEngine'] ?? '');
    $pDbVersion = (string)($p['databaseVersion'] ?? '');
    $pDb = ($pDbEngine !== '' && $pDbVersion !== '') ? "{$pDbEngine}:{$pDbVersion}" : '';
    $pDbId = (string)($p['databaseId'] ?? '');
    if ($pDbId === '' && $pDbEngine !== '' && $pDbVersion !== '') {
        $pDbId = $pDbEngine . '-' . str_replace('.', '-', $pDbVersion);
    }
    $pDbStatus = (string)($databases[$pDbId]['status'] ?? 'stopped');
    $pDatabaseHost = $pDbId !== '' ? "{$pDbId}.db.mpd.test" : '';
    $projectDriver = $pDbEngine === 'postgres' ? 'pgsql' : 'server';
    $pAdminerDbUrl = '';
    if ($pDatabaseHost !== '' && $pName !== '' && $pDbStatus === 'running') {
        $pAdminerDbUrl = "https://adminer.service.mpd.test/?{$projectDriver}={$pDatabaseHost}&username=" . rawurlencode($pName) . "&db=" . rawurlencode($pName);
    }
?>
    <tr>
        <td>
            <span class="status status-<?= h($statusClass) ?>"></span>
            <?= h($pName) ?>
        </td>
        <td class="meta"><?= h($pStatus) ?></td>
        <td class="meta">
            <?php if ($mainUrl !== ''): ?>
                <?php if ($running): ?>
                    <a href="<?= h($mainUrl) ?>"><?= h($mainUrl) ?></a>
                <?php else: ?>
                    <?= h($mainUrl) ?>
                <?php endif; ?>
            <?php endif; ?>
        </td>
        <td class="meta">
            <button popovertarget="<?= h($popoverId) ?>" class="expand" aria-label="details for <?= h($pName) ?>" style="anchor-name:--<?= h($popoverId) ?>">details</button>
        </td>
    </tr>
    <div popover id="<?= h($popoverId) ?>" class="popover" style="position-anchor:--<?= h($popoverId) ?>">
        <h3><?= h($pName) ?></h3>
        <dl class="props">
            <dt>Status</dt>   <dd><?= h($pStatus) ?></dd>
            <dt>Type</dt>     <dd><?= h($pType) ?></dd>
            <dt>Runtime</dt>  <dd><?= h($pRuntime !== '' ? $pRuntime : '—') ?></dd>
            <?php if ($pDb !== ''): ?>
            <dt>Database</dt>
            <dd>
                <?php if ($adminerRunning && $pAdminerDbUrl !== ''): ?>
                    <a href="<?= h($pAdminerDbUrl) ?>"><?= h($pDb) ?></a>
                <?php else: ?>
                    <?= h($pDb) ?>
                <?php endif; ?>
                <?php if ($pDatabaseHost !== ''): ?>
                    <span class="meta">@ <?= h($pDatabaseHost) ?></span>
                <?php endif; ?>
            </dd>
            <?php endif; ?>
            <dt>Webroot</dt>  <dd>/srv/projects/<?= h($pName) ?></dd>
        </dl>
        <?php if (!empty($pUrls)): ?>
            <h4>URLs</h4>
            <ul class="urls">
                <?php foreach ($pUrls as $u):
                    if (!is_array($u)) continue;
                    $uLabel = (string)($u['label'] ?? '');
                    $uKind = (string)($u['kind'] ?? '');
                    $uUrl = (string)($u['url'] ?? '');
                ?>
                <li>
                    <span class="kind-badge kind-<?= h($uKind) ?>"><?= h($uLabel !== '' ? $uLabel : $uKind) ?></span>
                    <?php if ($running): ?>
                        <a href="<?= h($uUrl) ?>"><?= h($uUrl) ?></a>
                    <?php else: ?>
                        <span class="meta"><?= h($uUrl) ?></span>
                    <?php endif; ?>
                </li>
                <?php endforeach; ?>
            </ul>
        <?php endif; ?>
        <?php if ($running && $pRuntime !== '' && projectTypeAllowsIdeLinks($pType)):
            $sshHost = "{$pRuntime}.runtime.mpd.test";
            $devUser = devUser();
            $projectPath = "/srv/projects/{$pName}";
            $vscodeUrl = "vscode://vscode-remote/ssh-remote+{$devUser}@{$sshHost}{$projectPath}";
        ?>
            <h4>Open in IDE</h4>
            <ul class="urls">
                <li>
                    <span class="kind-badge kind-ide">VS Code</span>
                    <a href="<?= h($vscodeUrl) ?>">Remote-SSH connect</a>
                </li>
                <li style="align-items:flex-start">
                    <span class="kind-badge kind-ide">PHPStorm</span>
                    <span class="meta">
                        Username: <?= h($devUser) ?><br>
                        Host: <?= h($sshHost) ?><br>
                        Port: 22<br>
                        Project directory: <?= h($projectPath) ?>
                    </span>
                </li>
            </ul>
        <?php endif; ?>
    </div>
<?php endforeach; ?>
</table>
<p class="note" style="margin-top: 0.6rem">Click "details" for project info. DB credentials: database, username, and password all match the project name.</p>
<?php endif; ?>

<h2>Runtimes</h2>
<?php if (empty($runtimes)): ?>
    <p class="none">No runtimes found.</p>
<?php else: ?>
<table>
<tr>
    <td class="meta">name</td>
    <td class="meta">status</td>
    <td class="meta">ip</td>
    <td class="meta">dns</td>
    <td class="meta">projects</td>
</tr>
<?php foreach ($runtimes as $rt): ?>
    <tr>
        <td>
            <span class="status status-<?= h($rt['status']) ?>"></span>
            <?= h($rt['name']) ?>
        </td>
        <td class="meta"><?= h($rt['status']) ?></td>
        <td class="meta"><?= h((string)$rt['ip']) ?></td>
        <td class="meta"><?= h((string)$rt['dns']) ?></td>
        <td class="meta"><?= h((string)$rt['projectCount']) ?></td>
    </tr>
<?php endforeach; ?>
</table>
<?php endif; ?>

<h2>Databases</h2>
<?php if (empty($databases)): ?>
    <p class="none">No databases found.</p>
<?php else: ?>
<table>
<tr>
    <td class="meta">database</td>
    <td class="meta">status</td>
    <td class="meta">dns</td>
    <td class="meta">projects</td>
</tr>
<?php foreach ($databases as $db): ?>
    <?php
        $dbEngine = (string)($db['engine'] ?? '');
        $dbStatus = (string)($db['status'] ?? 'stopped');
        $databaseHost = ((string)($db['databaseId'] ?? '')) . '.db.mpd.test';
        $projectCount = count($db['projects'] ?? []);
        $driver = $dbEngine === 'postgres' ? 'pgsql' : 'server';
        $superuser = $dbEngine === 'postgres' ? 'postgres' : 'root';
        $adminerUrl = "https://adminer.service.mpd.test/?{$driver}={$databaseHost}&username=" . rawurlencode($superuser);
    ?>
    <tr>
        <td>
            <span class="status status-<?= h($dbStatus) ?>"></span>
            <?= h($dbEngine . ':' . ((string)($db['version'] ?? ''))) ?>
        </td>
        <td class="meta"><?= h($dbStatus) ?></td>
        <td class="meta">
            <?php if ($adminerRunning && $dbStatus === 'running'): ?>
                <a href="<?= h($adminerUrl) ?>"><?= h($databaseHost) ?></a>
            <?php else: ?>
                <?= h($databaseHost) ?>
            <?php endif; ?>
        </td>
        <td class="meta"><?= h((string)$projectCount) ?></td>
    </tr>
<?php endforeach; ?>
</table>
<p class="note" style="margin-top: 0.3rem">Superuser credentials: postgres = postgres/postgres, mariadb = root/root, mysql = root/root.</p>
<?php endif; ?>

<h2>Services</h2>
<table>
<tr>
    <td class="meta">service</td>
    <td class="meta">status</td>
    <td class="meta">ip</td>
    <td class="meta">dns</td>
    <td class="meta">access</td>
</tr>
<?php foreach ($services as $svc): ?>
<tr>
    <td>
        <span class="status status-<?= h($svc['status']) ?>"></span>
        <?= h($svc['name']) ?>
    </td>
    <td class="meta"><?= h($svc['status']) ?></td>
    <td class="meta"><?= h($svc['ip']) ?></td>
    <td class="meta"><?= h($svc['dns']) ?></td>
    <td class="meta"><?= h($svc['access']) ?></td>
</tr>
<?php endforeach; ?>
</table>

<script>
// Smart auto-refresh: poll a state hash every 5s and reload only
// when the underlying data actually changed. The cost per poll is
// one stat() per relevant file — tiny.
//
// Open-popover survival: instead of suppressing reload while a
// popover is open (which hides state changes from the user), the
// open popover's id is mirrored into location.hash. After a reload
// the same popover is reopened on load — so you see fresh content
// AND your popover stays put.
//
// Background tabs throttle setInterval; visibilitychange catches
// that up by polling immediately when the tab regains visibility.
(() => {
    const initialHash = '<?= h(stateHash()) ?>';

    // Mirror the open popover into the URL hash.
    document.querySelectorAll('[popover]').forEach(p => {
        p.addEventListener('toggle', e => {
            if (e.newState === 'open') {
                history.replaceState(null, '', '#' + p.id);
            } else if (location.hash === '#' + p.id) {
                history.replaceState(null, '', location.pathname + location.search);
            }
        });
    });

    // Restore from hash on page load (covers fresh load and post-reload).
    const hashId = location.hash.replace(/^#/, '');
    if (hashId) {
        const el = document.getElementById(hashId);
        if (el && el.hasAttribute('popover') && typeof el.showPopover === 'function') {
            try { el.showPopover(); } catch (_) {}
        }
    }

    const poll = async () => {
        if (document.hidden) return;
        try {
            const r = await fetch('?hash=1', { cache: 'no-store' });
            if (!r.ok) return;
            const h = (await r.text()).trim();
            if (h && h !== initialHash) location.reload();
        } catch (_) { /* network blip — try again next tick */ }
    };
    console.log('mpd portal: auto-refresh poll armed (5s, hash=' + initialHash + ')');
    setInterval(poll, 5000);
    document.addEventListener('visibilitychange', () => {
        if (!document.hidden) poll();
    });
})();
</script>

</body>
</html>

