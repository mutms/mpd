<?php
// Tunnel/proxy diagnostic — dumps the request as Apache+PHP sees it.
// Useful for verifying what cloudflared (or any proxy) sends upstream.
// Drop into the portal container at /var/www/html/diag.php — any tunnel
// route pointing at https://<zone>/diag.php returns the dump.

die(); // remove this line when diagnosing cftunnel issues

header('Content-Type: text/plain; charset=utf-8');

echo "===== \$_SERVER =====\n";
var_dump($_SERVER);

echo "\n===== getallheaders() =====\n";
if (function_exists('getallheaders')) {
    var_dump(getallheaders());
} else {
    echo "(getallheaders unavailable)\n";
}

echo "\n===== php-fpm interesting bits =====\n";
foreach (['REMOTE_ADDR','HTTP_HOST','HTTP_X_FORWARDED_HOST','HTTP_X_FORWARDED_FOR',
          'HTTP_X_FORWARDED_PROTO','HTTP_CF_CONNECTING_IP','HTTP_CF_RAY',
          'HTTP_CF_VISITOR','HTTPS','REQUEST_SCHEME','SERVER_NAME','SERVER_PORT'] as $k) {
    printf("%-30s %s\n", $k, $_SERVER[$k] ?? '(unset)');
}
