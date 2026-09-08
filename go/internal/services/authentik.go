package services

import (
	"os"

	"github.com/mutms/mpd/go/internal/service"
)

// authentik — a test-only SAML/OIDC identity provider, used to exercise
// Moodle auth plugins (auth/saml2). It is not for managing mpd accounts.
// Unlike the other services it is a pod: authentik needs a server, a
// worker, PostgreSQL and Redis, sharing one address over localhost.
//
// The admin (akadmin) password comes from MPD_AUTHENTIK_ADMIN_PASSWORD;
// see docs/security.md. authentik reads the bootstrap variables only on
// its first start (a fresh database volume), so changing the password
// later needs `mpd --service-purge=authentik` then a restart.
func init() {
	const (
		image     = "ghcr.io/goauthentik/server:2026.8"
		dbPass    = "authentik-dev"
		secretKey = "mpd-authentik-dev-secret-key-not-for-production"
	)

	// server and worker share the pod's network namespace, so the
	// worker's own HTTP/metrics listeners must move off the server's
	// ports; the default 9000/9443/9300 collide otherwise and the
	// worker's task consumer never starts (blueprints never apply).
	workerListen := []string{
		"-e", "AUTHENTIK_LISTEN__HTTP=0.0.0.0:9001",
		"-e", "AUTHENTIK_LISTEN__HTTPS=0.0.0.0:9444",
		"-e", "AUTHENTIK_LISTEN__METRICS=0.0.0.0:9301",
	}

	// authentik must trust the mpd CA to fetch Moodle's SP metadata over
	// https://<project>.<zone>. The VM host's CA bundle already carries
	// the mpd anchor; mount it in and point Python (requests) and OpenSSL
	// at it. Read-only, public certs only — the CA key never enters here.
	caTrust := []string{
		"-v", "/etc/ssl/certs/ca-certificates.crt:/etc/ssl/certs/mpd-ca-bundle.crt:ro",
		"-e", "SSL_CERT_FILE=/etc/ssl/certs/mpd-ca-bundle.crt",
		"-e", "REQUESTS_CA_BUNDLE=/etc/ssl/certs/mpd-ca-bundle.crt",
	}

	// Fixed dev values keep this test IdP deterministic; a stable secret
	// key keeps sessions valid across restarts. Not production secrets.
	serverEnv := []string{
		"-e", "AUTHENTIK_SECRET_KEY=" + secretKey,
		"-e", "AUTHENTIK_POSTGRESQL__HOST=localhost",
		"-e", "AUTHENTIK_POSTGRESQL__USER=authentik",
		"-e", "AUTHENTIK_POSTGRESQL__PASSWORD=" + dbPass,
		"-e", "AUTHENTIK_POSTGRESQL__NAME=authentik",
		"-e", "AUTHENTIK_REDIS__HOST=localhost",
		"-e", "AUTHENTIK_DISABLE_UPDATE_CHECK=true",
		"-e", "AUTHENTIK_ERROR_REPORTING__ENABLED=false",
		"-e", "AUTHENTIK_LISTEN__HTTP=0.0.0.0:9000",
	}

	bootstrapEnv := []string{
		"-e", "AUTHENTIK_BOOTSTRAP_PASSWORD=" + envDefault("MPD_AUTHENTIK_ADMIN_PASSWORD", "authentik"),
		"-e", "AUTHENTIK_BOOTSTRAP_TOKEN=" + envDefault("MPD_AUTHENTIK_ADMIN_TOKEN", "mpd-authentik-dev-token"),
		"-e", "AUTHENTIK_BOOTSTRAP_EMAIL=" + envDefault("MPD_AUTHENTIK_ADMIN_EMAIL", "akadmin@authentik.test"),
	}

	service.Register(service.Service{
		Name:      "authentik",
		HostOctet: 101,
		Revision:  "3",
		Port:      9000,
		TLS:       true,
		PodContainers: []service.PodContainer{
			{
				Suffix:     "postgres",
				Image:      "docker.io/library/postgres:16-alpine",
				Volume:     "mpd-svc-authentik-db",
				VolumePath: "/var/lib/postgresql/data",
				RunArgs: []string{
					"-e", "POSTGRES_USER=authentik",
					"-e", "POSTGRES_PASSWORD=" + dbPass,
					"-e", "POSTGRES_DB=authentik",
				},
			},
			{
				Suffix: "redis",
				Image:  "docker.io/library/redis:7-alpine",
			},
			{
				Suffix:     "server",
				Primary:    true,
				Image:      image,
				Args:       []string{"server"},
				Volume:     "mpd-svc-authentik-media",
				VolumePath: "/media",
				RunArgs:    concat(serverEnv, caTrust),
			},
			{
				Suffix:     "worker",
				Image:      image,
				Args:       []string{"worker"},
				Volume:     "mpd-svc-authentik-media",
				VolumePath: "/media",
				RunArgs:    concat(serverEnv, workerListen, bootstrapEnv, caTrust),
			},
		},
	})
}

// concat joins RunArg slices left to right. A later -e for the same key
// wins, so workerListen overrides serverEnv's listen ports.
func concat(parts ...[]string) []string {
	var out []string
	for _, p := range parts {
		out = append(out, p...)
	}
	return out
}

// envDefault returns the environment variable value, or fallback when it
// is unset or empty.
func envDefault(key, fallback string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return fallback
}
