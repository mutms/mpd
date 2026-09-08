package services

import (
	"github.com/mutms/mpd/go/internal/net"
	"github.com/mutms/mpd/go/internal/service"
)

// zitadel — a test identity provider (SAML/OIDC), Go and container-native.
// It is a pod of the zitadel server plus its PostgreSQL. Served over HTTPS
// at zitadel.caddy.<zone>; the frontdoor reaches it over h2c because
// zitadel's gRPC needs HTTP/2. See docs/services/zitadel.md.
//
// This is a test IdP: the master key and database password are fixed dev
// constants (not secrets). The first admin password comes from
// MPD_ZITADEL_ADMIN_PASSWORD (default "Password1!", which meets zitadel's
// complexity policy). zitadel derives the admin login name from the
// external domain: zitadel-admin@zitadel.<ExternalDomain>, e.g.
// zitadel-admin@zitadel.zitadel.caddy.<zone>.
func init() {
	const (
		image     = "ghcr.io/zitadel/zitadel:v4.17.3"
		dbPass    = "zitadel-dev"
		masterKey = "MpdZitadelDevMasterKey0123456789" // exactly 32 chars
	)

	// zitadel must know its external URL at start. It is per-VM, so derive
	// the zone from this host; on a non-mpd host this stays empty and the
	// service simply cannot start, which is correct.
	externalDomain := "zitadel.caddy."
	if n, err := net.Current(); err == nil {
		externalDomain = "zitadel.caddy." + n.Zone()
	}

	adminPassword := envDefault("MPD_ZITADEL_ADMIN_PASSWORD", "Password1!")

	// zitadel must trust the mpd CA to fetch a project's SP metadata over
	// https://<project>.<zone> (SAML app import by URL). The VM host's CA
	// bundle carries the mpd anchor; mount it in and point Go's TLS at it
	// via SSL_CERT_FILE. Public anchor only — the CA key never enters.
	caTrust := []string{
		"-v", "/etc/ssl/certs/ca-certificates.crt:/etc/ssl/certs/mpd-ca-bundle.crt:ro",
		"-e", "SSL_CERT_FILE=/etc/ssl/certs/mpd-ca-bundle.crt",
	}

	zitadelEnv := []string{
		"-e", "ZITADEL_PORT=8080",
		"-e", "ZITADEL_EXTERNALDOMAIN=" + externalDomain,
		"-e", "ZITADEL_EXTERNALPORT=443",
		"-e", "ZITADEL_EXTERNALSECURE=true",
		"-e", "ZITADEL_TLS_ENABLED=false",
		// Embedded login (v1); no separate login-UI container, so the
		// frontdoor needs no path split.
		"-e", "ZITADEL_DEFAULTINSTANCE_FEATURES_LOGINV2_REQUIRED=false",
		"-e", "ZITADEL_DATABASE_POSTGRES_HOST=localhost",
		"-e", "ZITADEL_DATABASE_POSTGRES_PORT=5432",
		"-e", "ZITADEL_DATABASE_POSTGRES_DATABASE=zitadel",
		"-e", "ZITADEL_DATABASE_POSTGRES_USER_USERNAME=zitadel",
		"-e", "ZITADEL_DATABASE_POSTGRES_USER_PASSWORD=" + dbPass,
		"-e", "ZITADEL_DATABASE_POSTGRES_USER_SSLMODE=disable",
		"-e", "ZITADEL_DATABASE_POSTGRES_ADMIN_USERNAME=zitadel",
		"-e", "ZITADEL_DATABASE_POSTGRES_ADMIN_PASSWORD=" + dbPass,
		"-e", "ZITADEL_DATABASE_POSTGRES_ADMIN_SSLMODE=disable",
		"-e", "ZITADEL_FIRSTINSTANCE_ORG_HUMAN_PASSWORD=" + adminPassword,
		"-e", "ZITADEL_FIRSTINSTANCE_ORG_HUMAN_PASSWORDCHANGEREQUIRED=false",
	}

	service.Register(service.Service{
		Name:         "zitadel",
		HostOctet:    104,
		Revision:     "3",
		Port:         8080,
		TLS:          true,
		FrontdoorH2C: true,
		PodContainers: []service.PodContainer{
			{
				Suffix:     "postgres",
				Image:      "docker.io/library/postgres:17-alpine",
				Volume:     "mpd-svc-zitadel-db",
				VolumePath: "/var/lib/postgresql/data",
				RunArgs: []string{
					"-e", "POSTGRES_USER=zitadel",
					"-e", "POSTGRES_PASSWORD=" + dbPass,
					"-e", "POSTGRES_DB=zitadel",
				},
			},
			{
				Suffix:  "server",
				Primary: true,
				Image:   image,
				Args:    []string{"start-from-init", "--masterkey", masterKey, "--tlsMode", "external"},
				RunArgs: concat(zitadelEnv, caTrust),
			},
		},
	})
}
