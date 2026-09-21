# zitadel service

Start service in mpd:

`mpd --service-start=zitadel`

Log into the console as admin:

- URL: https://zitadel.caddy.NNN.mpd.test/
- Username: zitadel-admin@zitadel.zitadel.caddy.NNN.mpd.test
- Password: Password1! (or `MPD_ZITADEL_ADMIN_PASSWORD`)

IdP metadata of the instance: https://zitadel.caddy.NNN.mpd.test/saml/v2/metadata

## zitadel-admin

`zitadel-admin` drives the instance from the command line over the management API.

| Command                                              | Does                                          |
|------------------------------------------------------|-----------------------------------------------|
| `zitadel-admin <METHOD> <api path> [json body]`      | raw API call                                   |
| `zitadel-admin --token` / `--pat <token>`            | show or store the token it uses                |
| `zitadel-admin --saml-app <project> <sp metadata url>` | create or replace a SAML app from the metadata |
| `zitadel-admin --user <name> <password> [email] [first] [last]` | create or reset a human user       |

The token comes from `MPD_ZITADEL_PAT`, then `/srv/meta/zitadel/pat`, then the token the
instance writes at first init. An instance created before that existed has none, so make
a service user in the console with the ORG_OWNER role, add a personal access token to it,
and store it once with `zitadel-admin --pat <token>`.

## Create project for Moodle site

First create a new project, then and a new Application separately for
SAML2 and/or OIDC.

## Test user

Logins need a human user, the admin account is not a good test subject.

1. Users, New
2. fill in email, first and last name, set a password
3. tick "Email verified" and untick "Password change required", otherwise the first login
   asks for a new password
4. the login name is the user name without a domain suffix

### SAML

Set up steps must be done in the specified order.

Zitadel sends these attributes: `UserID`, `UserName`, `Email`, `FirstName`, `SurName` and
`FullName`. `UserID` is the permanent identifier, everything else can change.

Zitadel refuses single logout requests with `RequestDenied`, so a logout in Moodle ends
the Moodle session only.

#### auth_saml2

**In Moodle LMS**

1. install [auth_saml2](https://github.com/catalyst/moodle-auth_saml2) plugin
2. login as admin
3. enable auth_saml2 plugin
4. verify URL can be downloaded: https://<project>.NNN.mpd.test/auth/saml2/sp/metadata.php

**In Zitadel**

Create new Application from your Moodle project.

1. Name + Type: SAML
2. Specify metadata URL, or upload the file: https://<project>.NNN.mpd.test/auth/saml2/sp/metadata.php

Make sure "Use new Login UI" is OFF.

**In Moodle LMS**

1. set "IdP metadata xml OR public xml URL" to: https://zitadel.caddy.NNN.mpd.test/saml/v2/metadata
2. enable "auth_saml2 | debug"
3. got to /auth/test_settings.php?auth=saml2 and test login
4. use the debug info to set up saml to Moodle account mapping

#### auth_musaml

**In Moodle LMS**

1. install [auth_musaml](https://github.com/mutms/moodle-auth_musaml) plugin
2. login as admin, enable the SAML authentication plugin
3. go to Site administration, Plugins, Authentication, SAML authentication, Service provider
4. press "Generate certificate" and copy the service provider metadata URL:
   https://<project>.NNN.mpd.test/auth/musaml/metadata.php

**In Zitadel**, console or command line:

```
zitadel-admin --saml-app moodle https://<project>.NNN.mpd.test/auth/musaml/metadata.php
zitadel-admin --user testuser1 'Test-User-Pass1!'
```

By hand it is a new Application of type SAML in your project, with that metadata URL,
and "Use new Login UI" OFF, the new one does not carry SAML attributes yet.

**In Moodle LMS**

1. go to Identity providers and press "Add identity provider"
2. paste https://zitadel.caddy.NNN.mpd.test/saml/v2/metadata into "Metadata URL or XML",
   the provider is detected as Zitadel and the attribute mappings are prefilled
3. run "Test login" from the Attributes tab, the received values are listed under the
   mapped attributes and each unmapped one can be added with the plus icon
4. map the test user on the "Mapped users" tab, or turn on automatic mapping or automatic
   account creation for the identity provider

## OICD

**In Zitadel**

In project click add New Application and use following info in each numbered step:

1. Name + Type: Web
2. Auth method: Code
3. Redirect URI: https://<project>.NNN.mpd.test/auth/oidc/
4. Press Create button and copy **Client ID + Secret** (secret shown only *once*!)

Make sure "Use new Login UI" is OFF.

**In Moodle LMS**

1. install [auth_oidc](https://github.com/microsoft/moodle-auth_oidc) plugin
2. login as admin, enable auth_oidc
3. in auth_oidc settings set:
   - Identity Provider (IdP) type: **OpenID Connect**
   - Client ID + Client Secret: from the Zitadel app (step 4 above)
   - Client authentication method: **Client secret sent in login request** (matches "Code")
   - Authorization endpoint: `https://zitadel.caddy.NNN.mpd.test/oauth/v2/authorize`
   - Token endpoint: `https://zitadel.caddy.NNN.mpd.test/oauth/v2/token`
4. go to the Moodle login page and use the OpenID Connect link to test login
5. map fields under auth_oidc "Field mapping" (e.g. email → `email`, given_name → `firstname`, family_name → `lastname`)

## Automated tests of auth_musaml

The tests create their own Zitadel project named after the test database, register a SAML
application in it from the current service provider metadata, and log in as a real user.
No manual project is needed.

**In Zitadel**

1. Users, Service Users, New: user name `moodle-test-automation`, Access Token Type **Bearer**
2. open it, Personal Access Tokens, Add, set a far expiry and copy the token, it is shown only once
3. Organization, Members, Add member: the service user with the **ORG_OWNER** role, the tests
   create projects and applications
4. create a human test user as described above

**In Moodle LMS**

Add the constants to `config.php`, both test runners read them:

```php
define('TEST_AUTH_MUSAML_ZITADEL_URL', 'https://zitadel.caddy.NNN.mpd.test');
define('TEST_AUTH_MUSAML_ZITADEL_PAT', '<personal access token>');
define('TEST_AUTH_MUSAML_ZITADEL_USERNAME', '<login name of the human user>');
define('TEST_AUTH_MUSAML_ZITADEL_PASSWORD', '<password of that user>');
```

Then run the tests:

| Task    | Command                             |
|---------|-------------------------------------|
| PHPUnit | `phpunit --filter=auth_musaml`      |
| Behat   | `behat --tags=@auth_musaml_zitadel` |

Without the constants these tests are skipped and the rest of the suite still runs.

Notes:

- the application metadata is replaced on every run, test sites regenerate the service
  provider certificate
- PHPUnit and Behat get separate projects, the name comes from the database name and prefix
- the test helpers clear `curlsecurityblockedhosts`, the site must reach the Zitadel host
