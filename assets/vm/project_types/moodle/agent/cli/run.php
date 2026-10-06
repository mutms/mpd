<?php
// Runner behind mdl-agent-php: load the project's Moodle as a CLI script,
// then run a snippet or a file in the global scope, where $CFG, $DB and
// $USER are at hand.
//
// Arguments: <project dir> <username or ""> <"code"|"file"> <code or path> [args...]
// The snippet or file sees its own arguments in $argv, name first.

define('CLI_SCRIPT', true);

$mdlagent = (object)[
    'projectdir' => $argv[1] ?? '',
    'username' => $argv[2] ?? '',
    'mode' => $argv[3] ?? '',
    'source' => $argv[4] ?? '',
];
if (!is_file($mdlagent->projectdir . '/config.php')) {
    fwrite(STDERR, "mdl-agent-php: config.php not found in '{$mdlagent->projectdir}'\n");
    exit(1);
}

$argv = array_merge(
    [$mdlagent->mode === 'file' ? $mdlagent->source : 'mdl-agent-php'],
    array_slice($argv, 5)
);
$argc = count($argv);
$_SERVER['argv'] = $argv;
$_SERVER['argc'] = $argc;

require $mdlagent->projectdir . '/config.php';

if ($mdlagent->username !== '') {
    $mdlagent->user = $DB->get_record('user', ['username' => $mdlagent->username, 'deleted' => 0]);
    if (!$mdlagent->user) {
        fwrite(STDERR, "mdl-agent-php: user '{$mdlagent->username}' not found\n");
        exit(1);
    }
    \core\session\manager::set_user($mdlagent->user);
}

if ($mdlagent->mode === 'file') {
    require $mdlagent->source;
} else {
    eval($mdlagent->source . ';');
}
