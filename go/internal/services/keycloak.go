package services

import (
	"github.com/mutms/mpd/go/internal/net"
	"github.com/mutms/mpd/go/internal/service"
)

// keycloak — a test identity provider (SAML/OIDC), the one most Moodle
// sites run in house. Served over HTTPS at keycloak.caddy.<zone> through
// the frontdoor; plain HTTP/1.1 is enough, unlike zitadel it has no gRPC.
// See docs/services/keycloak.md.
//
// This is a test IdP: it runs in development mode with the bundled H2
// database on a volume, so a realm survives a stop/start but nothing here
// is meant for real accounts. The first admin password comes from
// MPD_KEYCLOAK_ADMIN_PASSWORD (default "Password1!"), the user is "admin".
func init() {
	const image = "quay.io/keycloak/keycloak:26.4"

	// Keycloak must know the URL the browser uses, it builds SAML and OIDC
	// endpoints from it. It is per-VM, so derive the zone from this host.
	hostname := "https://keycloak.caddy."
	if n, err := net.Current(); err == nil {
		hostname += n.Zone()
	}

	adminPassword := envDefault("MPD_KEYCLOAK_ADMIN_PASSWORD", "Password1!")

	// Keycloak must trust the mpd CA to import a project's SP metadata from
	// https://<project>.<zone>. The VM host's CA bundle carries the mpd
	// anchor; mount it in and point the Java truststore at it. Public
	// anchor only — the CA key never enters.
	caTrust := []string{
		"-v", "/etc/ssl/certs/ca-certificates.crt:/etc/ssl/certs/mpd-ca-bundle.crt:ro",
		"-e", "KC_TRUSTSTORE_PATHS=/etc/ssl/certs/mpd-ca-bundle.crt",
	}

	keycloakEnv := []string{
		"-e", "KC_BOOTSTRAP_ADMIN_USERNAME=admin",
		"-e", "KC_BOOTSTRAP_ADMIN_PASSWORD=" + adminPassword,
		"-e", "KC_HOSTNAME=" + hostname,
		// The frontdoor terminates TLS and forwards over plain HTTP.
		"-e", "KC_HTTP_ENABLED=true",
		"-e", "KC_PROXY_HEADERS=xforwarded",
		"-e", "KC_HEALTH_ENABLED=true",
		// The framework runs a single container image with no command, so the
		// start verb travels as an entrypoint override.
		"--entrypoint", `["/opt/keycloak/bin/kc.sh","start-dev"]`,
	}

	service.Register(service.Service{
		Name:       "keycloak",
		HostOctet:  105,
		Image:      image,
		Revision:   "1",
		Volume:     "mpd-svc-keycloak",
		VolumePath: "/opt/keycloak/data",
		Port:       8080,
		TLS:        true,
		RunArgs:    concat(keycloakEnv, caTrust),
	})
}
