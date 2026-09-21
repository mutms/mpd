# keycloak service

Start service in mpd:

`mpd --service-start=keycloak`

Log into the admin console:

- URL: https://keycloak.caddy.NNN.mpd.test/
- Username: admin
- Password: Password1! (or `MPD_KEYCLOAK_ADMIN_PASSWORD`)

IdP metadata of a realm: https://keycloak.caddy.NNN.mpd.test/realms/<realm>/protocol/saml/descriptor

The service runs in development mode with the bundled H2 database on a volume, so realms
survive a stop and start. It is a test identity provider, nothing here is meant for real
accounts.

## keycloak-admin

`keycloak-admin` drives the instance from the command line, so a test setup needs no
clicking. It wraps `kcadm.sh` inside the container and talks to the admin API for the
things kcadm cannot do.

| Command                                              | Does                                                        |
|------------------------------------------------------|-------------------------------------------------------------|
| `keycloak-admin <kcadm arguments>`                   | any kcadm command, the login is handled                      |
| `keycloak-admin --user <name> <password> [email] [first] [last]` | create or reset a user, email verified, no password change |
| `keycloak-admin --saml-client <name> <sp metadata url>` | create or replace a SAML client from the service provider metadata |
| `keycloak-admin --saml-mappers <clientId>`           | add the username, email and name mappers                     |

## SAML

Keycloak sends no attributes at all unless the client has protocol mappers, and every
realm ships a `role_list` scope that sends one `Role` attribute per role.

Keycloak encrypts assertions with RSA-OAEP and SHA-256 when the service provider
metadata offers an encryption certificate. Neither the php-saml nor the SimpleSAMLphp
stack in Moodle can decrypt that. `keycloak-admin --saml-client` therefore sets the
client to `rsa-oaep-mgf1p` with SHA-1 and MGF1-SHA1, which both understand. Doing it by
hand in the console means the three Encryption fields in the client's advanced settings,
or turning encryption off.

### auth_musaml

**In Moodle LMS**

1. install [auth_musaml](https://github.com/mutms/moodle-auth_musaml), enable it
2. Site administration, Plugins, Authentication, SAML authentication, Service provider
3. press "Generate certificate", the values below are listed on the Identity providers page

**In the VM**

```
keycloak-admin --saml-client moodle https://<project>.NNN.mpd.test/auth/musaml/metadata.php
keycloak-admin --saml-mappers https://<project>.NNN.mpd.test/auth/musaml/metadata.php
keycloak-admin --user testuser1 'Test-User-Pass1!'
```

**In Moodle LMS**

1. Identity providers, Add identity provider
2. paste https://keycloak.caddy.NNN.mpd.test/realms/master/protocol/saml/descriptor
3. the provider is detected as Keycloak, the usual attribute mappings are prefilled
4. Test login from the Attributes tab shows what arrives, then map the user

Keycloak accepts logout requests, so single logout works, unlike zitadel.

### auth_saml2

Same client and mappers, with the other metadata URL:

```
keycloak-admin --saml-client moodle-saml2 https://<project>.NNN.mpd.test/auth/saml2/sp/metadata.php
keycloak-admin --saml-mappers https://<project>.NNN.mpd.test/auth/saml2/sp/metadata.php
```

Then set "IdP metadata xml OR public xml URL" to the realm descriptor URL above.

## Automated tests of auth_musaml

The tests create their own realm named after the test database, with one SAML client and
one user in it, so parallel sites never collide. Add two constants to `config.php`:

```php
define('TEST_AUTH_MUSAML_KEYCLOAK_URL', 'https://keycloak.caddy.NNN.mpd.test');
define('TEST_AUTH_MUSAML_KEYCLOAK_PASSWORD', 'Password1!');
```

Then run the tests:

| Task    | Command                              |
|---------|--------------------------------------|
| PHPUnit | `phpunit --filter=auth_musaml`       |
| Behat   | `behat --tags=@auth_musaml_keycloak` |

Without the constants these tests are skipped. The Behat feature covers a login and a
single logout.
