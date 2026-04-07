<VirtualHost *:80>
    ServerName {{SERVER_NAME}}
    Redirect permanent / https://{{SERVER_NAME}}/
</VirtualHost>

<VirtualHost *:443>
    ServerName {{SERVER_NAME}}
    SSLEngine on
    SSLCertificateFile    {{CERT_FILE}}
    SSLCertificateKeyFile {{KEY_FILE}}

    ProxyPass        / {{UPSTREAM_URL}}/
    ProxyPassReverse / {{UPSTREAM_URL}}/
</VirtualHost>
