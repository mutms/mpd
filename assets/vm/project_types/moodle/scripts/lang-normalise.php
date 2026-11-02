<?php
// Normaliser behind mdl-lang-normalise. Keeps everything above the first
// $string, then writes the strings sorted by key with var_export.
//
// Arguments: <lang or empty for all> <check 0|1> <plugin dir>...

require(__DIR__ . '/lang-lib.php');

$onlylang = $argv[1];
$checkonly = $argv[2] === '1';
$dirs = array_slice($argv, 3);

$problems = 0;
$changed = 0;
$files = 0;

foreach ($dirs as $dir) {
    $dir = rtrim($dir, '/');
    $langfiles = glob($onlylang === '' ? "$dir/lang/*/*.php" : "$dir/lang/$onlylang/*.php") ?: [];
    if (!$langfiles) {
        echo "$dir: no language files\n";
        continue;
    }
    foreach ($langfiles as $file) {
        $label = $dir . substr($file, strlen($dir));
        $files++;
        $loaded = mdl_lang_load($file);
        if ($loaded['problems']) {
            echo "$label: cannot be loaded\n";
            foreach ($loaded['problems'] as $problem) {
                echo "  $problem\n";
            }
            $problems++;
            continue;
        }
        $content = mdl_lang_export($loaded['header'], $loaded['strings']);
        if ($content === file_get_contents($file)) {
            continue;
        }
        $changed++;
        if ($checkonly) {
            echo "$label: not normalised\n";
            continue;
        }
        file_put_contents($file, $content);
        if (function_exists('opcache_invalidate')) {
            opcache_invalidate($file, true);
        }
        $expected = $loaded['strings'];
        ksort($expected, SORT_STRING);
        if (mdl_lang_include($file) !== $expected) {
            echo "$label: strings changed by normalising, check git diff\n";
            $problems++;
            continue;
        }
        echo "$label: normalised\n";
    }
}

if ($checkonly) {
    echo "$files file(s), $changed not normalised, $problems with errors\n";
} else {
    echo "$files file(s), $changed normalised, $problems with errors\n";
}
exit(($problems || ($checkonly && $changed)) ? 1 : 0);
