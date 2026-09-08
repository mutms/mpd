# zitadel service

Start service in mpd:

`mpd --service-start=zitadel`

Log into the console as admin:

- URL: https://zitadel.caddy.NNN.mpd.test/
- Username: zitadel-admin@zitadel.zitadel.caddy.NNN.mpd.test
- Password: Password1! (or `MPD_ZITADEL_ADMIN_PASSWORD`)

## Create project for Moodle site

First create a new project, then and a new Application separately for
SAML2 and/or OIDC.

### SAML

Set up steps must be done in the specified order.

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

1. set "IdP metadata xml OR public xml URL" to: https://zitadel.caddy.NNN.mpd.test/.well-known/openid-configuration
2. enable "auth_saml2 | debug"
3. got to /auth/test_settings.php?auth=saml2 and test login
4. use the debug info to set up saml to Moodle account mapping

## OICD

**In Zitadel**

In project click add New Application and use following info in each numbered step:

1. Name + Type: Web
2. Auth method: Code
3. Redirect URI: `https://<project>.NNN.mpd.test/auth/oidc/`
4. Press Create button and copy **Client ID + Secret** (secret shown only *once*!)

Make sure "Use new Login UI" is OFF.

### In Moodle LMS

TODO: set up auth
