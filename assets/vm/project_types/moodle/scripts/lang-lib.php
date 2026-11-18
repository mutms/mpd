<?php
// Shared code of the mdl-lang-* helpers. Language files are loaded with
// include, the way Moodle loads them, so only use these on trusted plugins.

if (!defined('MOODLE_INTERNAL')) {
    define('MOODLE_INTERNAL', true);
}

/**
 * Strings of a language file, loaded the way Moodle does.
 *
 * @param string $file
 * @return array
 */
function mdl_lang_include(string $file): array {
    $string = [];
    include($file);
    return $string;
}

/**
 * Load one language file: header (everything above the first $string[) and
 * strings included the way Moodle does.
 *
 * @param string $file
 * @return array{header: string, strings: array, problems: string[]}
 */
function mdl_lang_load(string $file): array {
    $content = (string)file_get_contents($file);
    $pos = strpos($content, '$string[');
    $result = ['header' => $pos === false ? $content : substr($content, 0, $pos), 'strings' => [], 'problems' => []];
    try {
        $result['strings'] = mdl_lang_include($file);
    } catch (\Throwable $e) {
        $result['problems'][] = 'ERROR ' . $e->getMessage() . ' on line ' . $e->getLine();
    }
    return $result;
}

/**
 * Language file content in the standard form: the header unchanged, then
 * strings sorted by key, one statement per string.
 *
 * @param string $header
 * @param array $strings
 * @return string
 */
function mdl_lang_export(string $header, array $strings): string {
    ksort($strings, SORT_STRING);
    $content = $header;
    foreach ($strings as $key => $value) {
        $content .= '$string[' . var_export((string)$key, true) . '] = ' . var_export((string)$value, true) . ";\n";
    }
    return $content;
}

/**
 * Plugin directory in a Moodle checkout, with or without the public/ directory.
 *
 * @param string $root
 * @param string $path plugin path relative to dirroot, for example admin/tool/muprog
 * @return string|null
 */
function mdl_lang_plugin_dir(string $root, string $path): ?string {
    $root = rtrim($root, '/');
    $path = trim(preg_replace('#^public/#', '', $path), '/');
    foreach (["$root/public/$path", "$root/$path"] as $dir) {
        if (is_dir($dir)) {
            return $dir;
        }
    }
    return null;
}

/**
 * Plugin directory given on the command line of a tool that works in one project.
 *
 * An existing directory is used as it is. Otherwise the path is tried relative to
 * the dirroot of the project, so admin/tool/muprog works with and without public/.
 *
 * @param string $projectroot
 * @param string $dir
 * @return string|null null if there is no such directory
 */
function mdl_lang_resolve_dir(string $projectroot, string $dir): ?string {
    $dir = rtrim($dir, '/');
    if ($dir === '') {
        return null;
    }
    if (is_dir($dir)) {
        return $dir;
    }
    if (str_starts_with($dir, '/') || $projectroot === '') {
        return null;
    }
    $found = mdl_lang_plugin_dir($projectroot, $dir);
    if ($found === null) {
        return null;
    }
    // Keep the report short when the plugin is below the current directory.
    $cwd = rtrim((string)getcwd(), '/') . '/';
    return str_starts_with($found, $cwd) ? substr($found, strlen($cwd)) : $found;
}

/**
 * Standard header of a translation file, built from the header of the English
 * file: its licence lines, one PHPDoc block and whatever follows the English
 * PHPDoc block. The copyright lines of the translation are kept, the English
 * ones are used if it has none. The note about AI translation is kept if the
 * translation has it.
 *
 * @param string $enheader header of the lang/en file
 * @param string $header current header of the translation
 * @param string $lang language code
 * @param bool $reviewed drop the note about AI translation
 * @return string|null null if the English header has no PHPDoc block with @package
 */
function mdl_lang_template_header(string $enheader, string $header, string $lang, bool $reviewed = false): ?string {
    if (!preg_match('/\/\*\*\n.*? \*\/\n/s', $enheader, $doc, PREG_OFFSET_CAPTURE)
            || !preg_match('/@package\s+(\S+)/', $doc[0][0], $package)) {
        return null;
    }
    $licence = substr($enheader, 0, $doc[0][1]);
    $tail = substr($enheader, $doc[0][1] + strlen($doc[0][0]));
    $component = $package[1];

    if (!preg_match_all('/^ \* @copyright\s+(.+?)\s*$/m', $header, $copyrights)) {
        preg_match_all('/^ \* @copyright\s+(.+?)\s*$/m', $doc[0][0], $copyrights);
    }

    $name = class_exists(\Locale::class) ? (string)\Locale::getDisplayLanguage($lang, 'en') : '';
    $name = ($name === '' || $name === $lang) ? '' : $name . ' ';

    $result = $licence . "/**\n * Strings for component '$component', language '$lang'.\n *\n";
    if (!$reviewed && str_contains($header, 'produced automatically by an AI')) {
        $result .= wordwrap(" * NOTE: This {$name}translation was produced automatically by an AI language model and has"
            . " not yet been reviewed by a human translator. Corrections are welcome.", 80, "\n * ") . "\n *\n";
    }
    $result .= " * @package    $component\n";
    foreach ($copyrights[1] as $copyright) {
        $result .= " * @copyright  $copyright\n";
    }
    $result .= " * @license    https://www.gnu.org/copyleft/gpl.html GNU GPL v3 or later\n */\n";
    return $result . $tail;
}

/**
 * Plugins of a Moodle checkout that ship translations: directories with
 * version.php, lang/en and at least one more language.
 *
 * @param string $root project root
 * @param string $lang only plugins with this language, empty for any
 * @return string[] plugin paths relative to dirroot, for example admin/tool/muprog
 */
function mdl_lang_find_plugins(string $root, string $lang = ''): array {
    $root = rtrim($root, '/');
    $dirroot = is_dir("$root/public") ? "$root/public" : $root;
    $found = [];
    exec('find ' . escapeshellarg($dirroot) . ' -maxdepth 8 -type d'
        . ' \( -name node_modules -o -name vendor -o -name .git -o -name tests \) -prune'
        . " -o -type d -path '*/lang/en' -print", $found);
    $paths = [];
    foreach ($found as $endir) {
        $dir = dirname($endir, 2);
        if (!file_exists("$dir/version.php")) {
            continue;
        }
        if ($lang !== '' ? !is_dir("$dir/lang/$lang") : count(glob("$dir/lang/*", GLOB_ONLYDIR) ?: []) < 2) {
            continue;
        }
        $paths[] = substr($dir, strlen($dirroot) + 1);
    }
    sort($paths);
    return $paths;
}

/**
 * Forbidden terms of translations, read from a text file. Each line is a
 * language code, a PCRE pattern in slashes and an optional note:
 *
 *   it /ricertific/i use rinnovo
 *
 * Empty lines and lines starting with # are ignored.
 *
 * @param string $file
 * @return array{terms: array<string, array<int, array{pattern: string, note: string}>>, problems: string[]}
 */
function mdl_lang_load_terms(string $file): array {
    $result = ['terms' => [], 'problems' => []];
    foreach (file($file, FILE_IGNORE_NEW_LINES) ?: [] as $number => $line) {
        $line = trim($line);
        if ($line === '' || $line[0] === '#') {
            continue;
        }
        if (!preg_match('#^(\S+)\s+(/(?:[^/\\\\]|\\\\.)+/[imsx]*)(?:\s+(.*))?$#', $line, $m)
                || @preg_match($m[2] . 'u', '') === false) {
            $result['problems'][] = basename($file) . ' line ' . ($number + 1) . ': not "<lang> /pattern/ note"';
            continue;
        }
        $result['terms'][$m[1]][] = ['pattern' => $m[2], 'note' => $m[3] ?? ''];
    }
    return $result;
}

/**
 * Other checkouts next to the project that have the same plugin repository
 * on the same branch, so a change is made in one of them and pulled in the rest.
 *
 * @param string $root project root
 * @param string $path plugin path relative to dirroot
 * @return array{branch: string, projects: string[]}|null null if the plugin is not a git repository of its own
 */
function mdl_lang_shared_branch(string $root, string $path): ?array {
    $info = function (?string $dir): ?string {
        if ($dir === null || !file_exists("$dir/.git")) {
            return null;
        }
        $git = 'git -C ' . escapeshellarg($dir);
        $branch = trim((string)shell_exec("$git rev-parse --abbrev-ref HEAD 2>/dev/null"));
        $url = trim((string)shell_exec("$git config remote.origin.url 2>/dev/null"));
        return ($branch === '' || $branch === 'HEAD' || $url === '') ? null : "$url $branch";
    };
    $root = rtrim((string)realpath($root), '/');
    $mine = $info(mdl_lang_plugin_dir($root, $path));
    if ($mine === null) {
        return null;
    }
    $projects = [];
    foreach (glob(dirname($root) . '/*', GLOB_ONLYDIR) ?: [] as $other) {
        if ($other !== $root && $info(mdl_lang_plugin_dir($other, $path)) === $mine) {
            $projects[] = basename($other);
        }
    }
    return ['branch' => substr($mine, strrpos($mine, ' ') + 1), 'projects' => $projects];
}
