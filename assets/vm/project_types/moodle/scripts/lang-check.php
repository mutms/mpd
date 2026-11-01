<?php
// Checker behind mdl-lang-check. Language files are parsed and never run,
// so it needs no Moodle and is safe on any plugin.
//
// Arguments: <lang or empty for all> <same 0|1> <plugin dir>...

/**
 * Strings of one language file, without running it.
 *
 * @param string $file
 * @return array
 */
function mdl_lang_check_load(string $file): array {
    $strings = [];
    $tokens = array_values(array_filter(
        token_get_all(file_get_contents($file)),
        fn($token) => !(is_array($token) && in_array($token[0], [T_WHITESPACE, T_COMMENT, T_DOC_COMMENT]))
    ));
    $count = count($tokens);
    for ($i = 0; $i + 5 < $count; $i++) {
        $isstring = is_array($tokens[$i]) && $tokens[$i][0] === T_VARIABLE && $tokens[$i][1] === '$string';
        if (!$isstring || $tokens[$i + 1] !== '[' || !is_array($tokens[$i + 2]) || $tokens[$i + 3] !== ']' || $tokens[$i + 4] !== '=') {
            continue;
        }
        $value = '';
        for ($j = $i + 5; $j < $count && $tokens[$j] !== ';'; $j++) {
            if (is_array($tokens[$j]) && $tokens[$j][0] === T_CONSTANT_ENCAPSED_STRING) {
                $value .= mdl_lang_check_unquote($tokens[$j][1]);
            }
        }
        $strings[mdl_lang_check_unquote($tokens[$i + 2][1])] = $value;
    }
    return $strings;
}

/**
 * Value of a PHP string literal.
 *
 * @param string $literal
 * @return string
 */
function mdl_lang_check_unquote(string $literal): string {
    $body = substr($literal, 1, -1);
    if ($literal[0] === "'") {
        return str_replace(["\\\\", "\\'"], ["\\", "'"], $body);
    }
    return stripcslashes($body);
}

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
            $lint = [];
            exec(escapeshellarg(PHP_BINARY) . ' -l ' . escapeshellarg($file) . ' 2>&1', $lint, $status);
            if ($status !== 0) {
                echo "$dir: lang/$lang/$name\n  SYNTAX " . implode(' ', $lint) . "\n";
                $problems++;
                continue;
            }

            if (mdl_lang_check_header($enfile) !== mdl_lang_check_header($file)) {
                $errors[] = 'HEADER licence header differs from English';
            }

            $en = mdl_lang_check_load($enfile);
            $strings = mdl_lang_check_load($file);

            foreach (array_keys(array_diff_key($en, $strings)) as $key) {
                $errors[] = "MISSING $key";
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
