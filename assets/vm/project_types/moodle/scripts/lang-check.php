<?php
// Checker behind mdl-lang-check. Language files are loaded with include like
// Moodle does, Moodle itself is not needed.
//
// Arguments: <lang or empty for all> <same 0|1> <plugin dir>...

/**
 * Sorted parts of a string that must stay the same in every language.
 *
 * @param string $pattern
 * @param string $text
 * @return array
 */
function mdl_lang_check_tokens(string $pattern, string $text): array {
    preg_match_all($pattern, $text, $matches);
    sort($matches[0]);
    return $matches[0];
}

/**
 * The part of a language file above its PHPDoc block.
 *
 * @param string $file
 * @return string
 */
function mdl_lang_check_header(string $file): string {
    $content = file_get_contents($file);
    return substr($content, 0, (int)strpos($content, '/**'));
}

require(__DIR__ . '/lang-lib.php');

$onlylang = $argv[1];
$showsame = $argv[2] === '1';
$dirs = array_slice($argv, 3);

$tokenpattern = '/\{\$a(?:->[A-Za-z0-9_]+)?\}|\{no\}|<\/?[a-zA-Z][^>]*>|https?:\/\/[^\s\'"<)]+/u';
$codepattern = '/`[^`\n]+`/u';
$problems = 0;
$warnings = 0;

foreach ($dirs as $dir) {
    $dir = rtrim($dir, '/');
    $enfiles = glob("$dir/lang/en/*.php") ?: [];
    if (!$enfiles) {
        echo "$dir: no lang/en strings\n";
        $problems++;
        continue;
    }
    $langs = array_values(array_filter(array_map('basename', glob("$dir/lang/*", GLOB_ONLYDIR)), fn($lang) => $lang !== 'en'));
    if ($onlylang !== '') {
        $langs = [$onlylang];
    }
    if (!$langs) {
        echo "$dir: no translations\n";
        continue;
    }
    foreach ($langs as $lang) {
        foreach ($enfiles as $enfile) {
            $name = basename($enfile);
            $file = "$dir/lang/$lang/$name";
            if (!file_exists($file)) {
                echo "$dir: no lang/$lang/$name\n";
                continue;
            }

            $errors = [];
            $notes = [];

            $enloaded = mdl_lang_load($enfile);
            $loaded = mdl_lang_load($file);
            if ($enloaded['problems'] || $loaded['problems']) {
                echo "$dir: lang/$lang/$name\n";
                foreach ($enloaded['problems'] as $problem) {
                    echo "  en $problem\n";
                }
                foreach ($loaded['problems'] as $problem) {
                    echo "  $problem\n";
                }
                $problems += count($enloaded['problems']) + count($loaded['problems']);
                continue;
            }

            if (mdl_lang_check_header($enfile) !== mdl_lang_check_header($file)) {
                $errors[] = 'HEADER licence header differs from English';
            }

            $en = $enloaded['strings'];
            $strings = $loaded['strings'];

            // English variants such as en_us are child packs, they override only some strings.
            if (!str_starts_with($lang, 'en_')) {
                foreach (array_keys(array_diff_key($en, $strings)) as $key) {
                    $errors[] = "MISSING $key";
                }
            }
            foreach (array_keys(array_diff_key($strings, $en)) as $key) {
                $errors[] = "EXTRA $key";
            }
            if (array_keys(array_intersect_key($en, $strings)) !== array_keys(array_intersect_key($strings, $en))) {
                $errors[] = 'ORDER strings are not in the same order as English';
            }

            $same = 0;
            foreach ($en as $key => $value) {
                if (!isset($strings[$key])) {
                    continue;
                }
                $expected = mdl_lang_check_tokens($tokenpattern, $value);
                $actual = mdl_lang_check_tokens($tokenpattern, $strings[$key]);
                if ($expected !== $actual) {
                    $diff = array_merge(array_diff($expected, $actual), array_diff($actual, $expected));
                    $errors[] = "TOKENS $key: " . implode(' ', $diff);
                }
                $expected = mdl_lang_check_tokens($codepattern, $value);
                $actual = mdl_lang_check_tokens($codepattern, $strings[$key]);
                if ($expected !== $actual) {
                    $diff = array_merge(array_diff($expected, $actual), array_diff($actual, $expected));
                    $notes[] = "WARNING code differs $key: " . implode(' ', $diff);
                    $warnings++;
                }
                if ($value === $strings[$key] && preg_match('/[a-z]{3}/', $value)) {
                    $same++;
                    if ($showsame) {
                        $notes[] = "SAME $key: " . mb_substr($value, 0, 70);
                    }
                }
            }

            printf("%s: lang/%s/%s en=%d %s=%d same=%d\n", $dir, $lang, $name, count($en), $lang, count($strings), $same);
            foreach (array_merge($errors, $notes) as $line) {
                echo "  $line\n";
            }
            $problems += count($errors);
        }
    }
}

echo $problems ? "FAILED: $problems problem(s), $warnings warning(s)\n" : "OK, $warnings warning(s)\n";
exit($problems ? 1 : 0);
