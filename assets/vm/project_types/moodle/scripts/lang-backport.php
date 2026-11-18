<?php
// Backporter behind mdl-lang-backport. Copies translations of a plugin from
// another Moodle checkout, only where the English text is the same unless
// --changed is used. The result is written in the normalised form.
//
// Arguments: <lang or empty for all> <changed 0|1> <update 0|1> <dry run 0|1> <all 0|1>
//            <target only 0|1> <source root> <target root> <plugin path>...

require(__DIR__ . '/lang-lib.php');

[, $onlylang, $changed, $update, $dryrun, $all, $targetonly, $sourceroot, $targetroot] = $argv;
$changed = $changed === '1';
$update = $update === '1';
$dryrun = $dryrun === '1';
$paths = array_slice($argv, 9);

$problems = 0;

if ($all === '1') {
    $missing = [];
    foreach (mdl_lang_find_plugins($sourceroot, $onlylang) as $path) {
        if (mdl_lang_plugin_dir($targetroot, $path)) {
            $paths[] = $path;
        } else {
            $missing[] = $path;
        }
    }
    if ($missing) {
        echo "Not in this project: " . implode(', ', $missing) . "\n";
    }
}

/**
 * One line of a string for the report.
 *
 * @param string $text
 * @return string
 */
function mdl_lang_backport_show(string $text): string {
    return str_replace("\n", "\n      ", $text);
}

foreach ($paths as $path) {
    $sourcedir = mdl_lang_plugin_dir($sourceroot, $path);
    $targetdir = mdl_lang_plugin_dir($targetroot, $path);
    if (!$sourcedir || !$targetdir) {
        echo "$path: not found in " . ($sourcedir ? 'target' : 'source') . "\n";
        $problems++;
        continue;
    }
    $langs = $onlylang !== '' ? [$onlylang] : array_values(array_filter(
        array_map('basename', glob("$sourcedir/lang/*", GLOB_ONLYDIR) ?: []),
        fn($lang) => $lang !== 'en'
    ));
    if (!$langs) {
        echo "$path: no translations in source\n";
        continue;
    }

    $written = false;
    foreach ($langs as $lang) {
        foreach (glob("$targetdir/lang/en/*.php") ?: [] as $targetenfile) {
            $name = basename($targetenfile);
            $label = "$path: lang/$lang/$name";
            $sourcefile = "$sourcedir/lang/$lang/$name";
            $targetfile = "$targetdir/lang/$lang/$name";
            if (!file_exists($sourcefile)) {
                echo "$label: no source translation\n";
                continue;
            }

            $loaded = [
                'source en' => mdl_lang_load("$sourcedir/lang/en/$name"),
                'source' => mdl_lang_load($sourcefile),
                'target en' => mdl_lang_load($targetenfile),
            ];
            if (file_exists($targetfile)) {
                $loaded['target'] = mdl_lang_load($targetfile);
            }
            $failed = false;
            foreach ($loaded as $which => $result) {
                foreach ($result['problems'] as $problem) {
                    echo "$label: $which $problem\n";
                    $failed = true;
                }
            }
            if ($failed) {
                echo "$label: not changed\n";
                $problems++;
                continue;
            }

            $sourceen = $loaded['source en']['strings'];
            $source = $loaded['source']['strings'];
            $targeten = $loaded['target en']['strings'];
            $header = isset($loaded['target']) ? $loaded['target']['header'] : $loaded['source']['header'];
            $target = isset($loaded['target']) ? $loaded['target']['strings'] : [];
            $result = $target;

            $lines = [];
            $count = ['added' => 0, 'changed' => 0, 'updated' => 0, 'differs' => 0, 'untranslated' => 0, 'targetonly' => 0];
            foreach ($targeten as $key => $en) {
                $sameen = array_key_exists($key, $sourceen) && $sourceen[$key] === $en;
                if (!array_key_exists($key, $source)) {
                    if (str_starts_with($lang, 'en_')) {
                        // English variants such as en_us are child packs, they override only some strings.
                        continue;
                    }
                    if (!array_key_exists($key, $target)) {
                        $count['untranslated']++;
                        $lines[] = "  UNTRANSLATED $key";
                    } else {
                        $count['targetonly']++;
                        $targetonly === '1' && $lines[] = "  TARGETONLY $key: " . mb_substr(strtok($target[$key], "\n"), 0, 70);
                    }
                    continue;
                }
                if (array_key_exists($key, $target)) {
                    if ($target[$key] === $source[$key]) {
                        continue;
                    }
                    if ($sameen && $update) {
                        $result[$key] = $source[$key];
                        $count['updated']++;
                        $lines[] = "  UPDATED $key";
                    } else {
                        $count['differs']++;
                        $lines[] = "  DIFFERS $key" . ($sameen ? ' (use --update)' : ' (English differs too)');
                    }
                    continue;
                }
                if ($sameen) {
                    $result[$key] = $source[$key];
                    $count['added']++;
                    continue;
                }
                if (!$changed) {
                    $count['changed']++;
                    $count['untranslated']++;
                    $lines[] = "  CHANGED $key (use --changed)";
                    continue;
                }
                $result[$key] = $source[$key];
                $count['changed']++;
                $lines[] = "  REVIEW $key\n"
                    . "    source en: " . mdl_lang_backport_show($sourceen[$key] ?? '(none)') . "\n"
                    . "    target en: " . mdl_lang_backport_show($en) . "\n"
                    . "    imported:  " . mdl_lang_backport_show($source[$key]);
            }
            $extra = array_keys(array_diff_key($result, $targeten));
            foreach ($extra as $key) {
                $lines[] = "  EXTRA $key";
            }

            printf("%s: added %d, %s %d, %s %d, untranslated %d, target only %d, extra %d\n", $label, $count['added'],
                $changed ? 'changed imported' : 'changed skipped', $count['changed'],
                $update ? 'updated' : 'differs', $update ? $count['updated'] : $count['differs'],
                $count['untranslated'], $count['targetonly'], count($extra));
            foreach ($lines as $line) {
                echo "$line\n";
            }
            if ($count['untranslated']) {
                $problems++;
            }

            $content = mdl_lang_export($header, $result);
            if (!$result || (file_exists($targetfile) && file_get_contents($targetfile) === $content)) {
                continue;
            }
            $written = true;
            if ($dryrun) {
                continue;
            }
            if (!is_dir(dirname($targetfile))) {
                mkdir(dirname($targetfile), 0777, true);
            }
            file_put_contents($targetfile, $content);
        }
    }
    if ($written && ($shared = mdl_lang_shared_branch($targetroot, $path)) && $shared['projects']) {
        echo "  SHARED branch {$shared['branch']} is also checked out in " . implode(', ', $shared['projects'])
            . ", change one checkout and pull in the others\n";
    }
}

echo $dryrun ? "Dry run, nothing written\n" : '';
echo $problems ? "Incomplete: $problems file(s) with untranslated strings or problems\n" : "OK\n";
exit($problems ? 1 : 0);
