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
