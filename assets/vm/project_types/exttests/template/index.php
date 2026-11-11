<?php
// Start page of the Moodle external test files site. mpd seeds it once.

$h = fn($s) => htmlspecialchars((string)$s, ENT_QUOTES);
$host = $_SERVER['HTTP_HOST'] ?? '';
$rows = [
    'Protocol' => $_SERVER['SERVER_PROTOCOL'] ?? '',
    'HTTPS' => empty($_SERVER['HTTPS']) || $_SERVER['HTTPS'] === 'off' ? 'no' : 'yes',
    'PHP' => PHP_VERSION,
    'Directory' => __DIR__,
];
?>
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<title>Moodle external test files</title>
<style>
body { font-family: system-ui, sans-serif; margin: 2rem; max-width: 50rem; line-height: 1.5; }
th { text-align: left; padding-right: 1rem; }
code { background: #eee; padding: 0 .2rem; }
</style>
</head>
<body>
<h1>Moodle external test files</h1>
<p>This site serves the files that some Moodle PHPUnit tests download,
such as <a href="test.html">test.html</a> and
<a href="test_redir.php">test_redir.php</a>.</p>
<p>Moodle projects on this VM use it through
<code>TEST_EXTERNAL_FILES_HTTP_URL</code> and
<code>TEST_EXTERNAL_FILES_HTTPS_URL</code>. Keep the project running while
you run PHPUnit tests.</p>
<p>Both addresses must work:
<a href="http://<?= $h($host) ?>/">http://<?= $h($host) ?>/</a> and
<a href="https://<?= $h($host) ?>/">https://<?= $h($host) ?>/</a>.</p>
<h2>This request</h2>
<table>
<?php foreach ($rows as $name => $value): ?>
<tr><th><?= $h($name) ?></th><td><?= $h($value) ?></td></tr>
<?php endforeach; ?>
</table>
<p>The files come from
<a href="https://github.com/moodlehq/moodle-exttests">moodlehq/moodle-exttests</a>.</p>
</body>
</html>
