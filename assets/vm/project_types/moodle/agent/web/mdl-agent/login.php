<?php
// Log the browser in as the user a single-use token was issued for.
// The token comes from the mdl-agent-login tool. No password is involved,
// so nobody has to change one to get a browser session.

require __DIR__ . '/../../lib.php';

$data = mdl_agent_consume_token('login');
$projectdir = mdl_agent_project_dir();

require $projectdir . '/config.php';

$username = $data['username'] ?? '';
$user = is_string($username) ? get_complete_user_data('username', $username) : false;
if (!$user || $user->suspended) {
    mdl_agent_fail(403, 'mdl-agent: user cannot log in');
}

if (isloggedin() && $USER->id != $user->id) {
    require_logout();
}
complete_user_login($user);

// Only a local path is accepted, never another host.
$path = $data['path'] ?? '/';
if (!is_string($path) || !str_starts_with($path, '/') || str_starts_with($path, '//') || str_contains($path, '\\')) {
    $path = '/';
}

\core\session\manager::write_close();
header('Cache-Control: no-store');
header('Location: ' . $CFG->wwwroot . $path, true, 303);
exit;
