<?php
// Runner behind mdl-agent-downgrade; started through agent/cli/run.php, so
// Moodle is loaded. Lowers the version a plugin is recorded as installed
// at, so the next upgrade runs its upgrade steps again.
//
// Arguments: <component> <version>

[$mdlagentcomponent, $mdlagentversion] = [$argv[1] ?? '', $argv[2] ?? ''];

$mdlagentfail = function (string $message): never {
    fwrite(STDERR, "mdl-agent-downgrade: {$message}\n");
    exit(1);
};

// The same shape upgrade_plugin_savepoint() accepts: 2026100653 or 2026022045.02.
if (!preg_match('/^\d{10}(\.\d{1,2})?$/D', $mdlagentversion)) {
    $mdlagentfail("'{$mdlagentversion}' is not a plugin version such as 2026100653 or 2026022045.02");
}

[$mdlagenttype, $mdlagentname] = core_component::normalize_component($mdlagentcomponent);
if ($mdlagenttype === 'core') {
    $mdlagentfail('only plugins can be downgraded, not Moodle itself or its subsystems');
}
$mdlagentcomponent = $mdlagenttype . '_' . $mdlagentname;
$mdlagentdir = core_component::get_plugin_directory($mdlagenttype, $mdlagentname);
if (!$mdlagentdir) {
    $mdlagentfail("plugin '{$mdlagentcomponent}' is not in this code base");
}

$mdlagentinstalled = get_config($mdlagentcomponent, 'version');
if ($mdlagentinstalled === false || $mdlagentinstalled === '') {
    $mdlagentfail("plugin '{$mdlagentcomponent}' is not installed yet, an upgrade will install it");
}
if ((float)$mdlagentversion >= (float)$mdlagentinstalled) {
    $mdlagentfail("'{$mdlagentversion}' is not lower than the installed version {$mdlagentinstalled}");
}

$plugin = new stdClass();
$plugin->version = null;
include($mdlagentdir . '/version.php');
$mdlagentcode = $plugin->version;

set_config('version', $mdlagentversion, $mdlagentcomponent);
// Moodle decides whether an upgrade is due by comparing a hash of all
// code versions with the one stored at the last upgrade. Without clearing
// it the lowered version would go unnoticed.
unset_config('allversionshash');

echo "{$mdlagentcomponent}: installed version {$mdlagentinstalled} -> {$mdlagentversion}";
echo " (code is at {$mdlagentcode})\n";
echo "Only the recorded version changed: tables, fields and data stay as the earlier upgrade left them.\n";
echo "Run 'mdl-upgrade' to execute the upgrade steps above {$mdlagentversion} again.\n";
