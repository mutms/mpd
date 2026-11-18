<?php
// Report behind mdl-lang-dupes: English strings translated in more than one
// way, over all given plugins. Moodle is not needed.
//
// Arguments: <lang or empty for all> <min length> <all 0|1> <project root> <plugin dir>...

require(__DIR__ . '/lang-lib.php');

$onlylang = $argv[1];
$min = (int)$argv[2];
$projectroot = $argv[4];
$dirs = $argv[3] === '1' ? mdl_lang_find_plugins($projectroot, $onlylang) : array_slice($argv, 5);

$problems = 0;
// Language => English text => translation => list of "component key".
$groups = [];

foreach ($dirs as $dir) {
    $resolved = mdl_lang_resolve_dir($projectroot, $dir);
    if ($resolved === null) {
        echo "$dir: directory not found\n";
        $problems++;
        continue;
    }
    $dir = $resolved;
    foreach (glob("$dir/lang/en/*.php") ?: [] as $enfile) {
        $name = basename($enfile);
        $en = mdl_lang_load($enfile);
        $files = glob($onlylang === '' ? "$dir/lang/*/$name" : "$dir/lang/$onlylang/$name") ?: [];
        foreach ($files as $file) {
            $lang = basename(dirname($file));
            if ($lang === 'en' || str_starts_with($lang, 'en_')) {
                continue;
            }
            $loaded = mdl_lang_load($file);
            if ($en['problems'] || $loaded['problems']) {
                echo "$dir: lang/$lang/$name cannot be loaded\n";
                $problems++;
                continue;
            }
            foreach ($loaded['strings'] as $key => $value) {
                $text = trim($en['strings'][$key] ?? '');
                if ($text !== '' && mb_strlen($text) >= $min) {
                    $groups[$lang][$text][trim($value)][] = basename($name, '.php') . ' ' . $key;
                }
            }
        }
    }
}

$count = 0;
ksort($groups);
foreach ($groups as $lang => $texts) {
    foreach ($texts as $text => $translations) {
        if (count($translations) < 2) {
            continue;
        }
        $count++;
        echo "$lang: " . str_replace("\n", "\n    ", $text) . "\n";
        foreach ($translations as $translation => $keys) {
            echo "  " . implode(', ', $keys) . "\n    " . str_replace("\n", "\n    ", $translation) . "\n";
        }
    }
}

echo "$count English text(s) with different translations\n";
exit($problems ? 1 : 0);
