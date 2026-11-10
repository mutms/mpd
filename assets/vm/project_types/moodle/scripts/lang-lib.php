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
