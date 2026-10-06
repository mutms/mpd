<?php
// Shared helpers for the mdl-agent web scripts of Moodle projects.
//
// The frontdoor serves agent/web/mdl-agent/ under /mdl-agent/ on a project's
// main URL. That directory is mpd code and is never writable from a project.
// State lives in /srv/data/<project>/agent/, which is never served.
//
// Every script must start by consuming a token issued by a CLI tool, so the
// route as a whole stays closed to anybody without shell access to the VM.

/**
 * Stop with a plain text error.
 */
function mdl_agent_fail(int $status, string $message): never {
    http_response_code($status);
    header('Content-Type: text/plain; charset=utf-8');
    header('Cache-Control: no-store');
    echo $message . "\n";
    exit;
}

/**
 * Name of the project this request belongs to, set by the frontdoor.
 */
function mdl_agent_project(): string {
    $project = $_SERVER['MPD_PROJECT'] ?? '';
    if (!is_string($project) || !preg_match('/^[A-Za-z0-9][A-Za-z0-9_-]*$/D', $project)) {
        mdl_agent_fail(500, 'mdl-agent: project is not known');
    }
    return $project;
}

/**
 * Directory of the project checkout, set by the frontdoor.
 */
function mdl_agent_project_dir(): string {
    $dir = $_SERVER['MPD_PROJECT_DIR'] ?? '';
    if (!is_string($dir) || $dir === '' || !is_file($dir . '/config.php')) {
        mdl_agent_fail(500, 'mdl-agent: project directory is not known');
    }
    return $dir;
}

/**
 * Consume the single-use token from the request and return its data.
 *
 * Only the SHA-256 of a token is stored, as the name of a JSON file. The
 * file is claimed with an atomic rename before it is read, so two requests
 * with one token cannot both succeed.
 *
 * @param string $purpose what the token was issued for, such as "login"
 * @return array data stored with the token
 */
function mdl_agent_consume_token(string $purpose): array {
    $project = mdl_agent_project();

    $token = $_GET['token'] ?? '';
    if (!is_string($token) || !preg_match('/^[a-f0-9]{64}$/D', $token)) {
        mdl_agent_fail(403, 'mdl-agent: invalid token');
    }

    $file = '/srv/data/' . $project . '/agent/tokens/' . hash('sha256', $token) . '.json';
    $claimed = $file . '.' . bin2hex(random_bytes(8)) . '.used';
    if (!@rename($file, $claimed)) {
        mdl_agent_fail(403, 'mdl-agent: invalid or already used token');
    }
    $data = json_decode((string)file_get_contents($claimed), true);
    unlink($claimed);

    if (!is_array($data) || ($data['purpose'] ?? '') !== $purpose) {
        mdl_agent_fail(403, 'mdl-agent: invalid token');
    }
    if ((int)($data['expires'] ?? 0) < time()) {
        mdl_agent_fail(403, 'mdl-agent: expired token');
    }

    return $data;
}
