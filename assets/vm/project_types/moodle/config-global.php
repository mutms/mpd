<?php
// config-global.php — included at the end of every Moodle project's
// config-mpd.php. Seeded once to /var/lib/mpd/moodle/config-global.php,
// then yours to edit; it affects all Moodle projects at once.
// MPD_PROJECT_NAME identifies the including project.

// While a Cloudflare quick tunnel is active for this project
// (trycloudflare-start writes tunnel.json), the tunnel URL is the site's
// single canonical wwwroot. Moodle redirects .mpd.test visitors to it on
// its own. Removing the tunnel reverts wwwroot to the generated value.
if (defined('MPD_PROJECT_NAME')) {
    $mpd_tunnel = '/srv/meta/' . MPD_PROJECT_NAME . '/tunnel.json';
    if (is_readable($mpd_tunnel)) {
        $mpd_t = json_decode(file_get_contents($mpd_tunnel), true);
        if (!empty($mpd_t['url'])) {
            $CFG->wwwroot = $mpd_t['url'];
            $CFG->sslproxy = true;          // TLS terminates at Cloudflare's edge.
            $CFG->getremoteaddrconf = 1;    // Real client IP via X-Forwarded-For.
        }
        unset($mpd_t);
    }
    unset($mpd_tunnel);
}
