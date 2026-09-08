package services

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	gohttp "net/http"
	"os"
	"path/filepath"

	"github.com/mutms/mpd/go/internal/cert"
	"github.com/mutms/mpd/go/internal/net"
	"github.com/mutms/mpd/go/internal/podman"
	"github.com/mutms/mpd/go/internal/service"
)

// authentik LDAP. authentik serves LDAP from a dedicated outpost
// container, not the core, and the outpost authenticates with a
// service-account token the core generates. setupLDAP provisions the
// provider, application and outpost through the API (idempotent), uploads
// an mpd-signed LDAPS cert, reads the outpost token, and launches the
// outpost into the pod. Called from provisionAuthentik. See
// docs/architecture.md.

const (
	ldapImage        = "ghcr.io/goauthentik/ldap:2026.8"
	ldapOutpostName  = "mpd-ldap"
	ldapProviderName = "mpd-ldap"
	ldapAppSlug      = "mpd-ldap"
	ldapCertName     = "mpd-ldap"
	ldapBaseDN       = "dc=ldap,dc=mpd,dc=test"
)

func setupLDAP(ctx context.Context, out io.Writer, api *authentikAPI, s service.Service, n net.Net, p *podman.Client) error {
	authFlow, err := api.flowBySlug(ctx, "default-authentication-flow")
	if err != nil {
		return err
	}
	invFlow, err := api.flowBySlug(ctx, "default-provider-invalidation-flow")
	if err != nil {
		return err
	}

	provider, err := api.ensureLDAPProvider(ctx, authFlow, invFlow)
	if err != nil {
		return err
	}
	if err := api.ensureApplication(ctx, provider); err != nil {
		return err
	}
	if err := api.ensureLDAPSCert(ctx, out, provider, n); err != nil {
		return err
	}
	outpost, err := api.ensureOutpost(ctx, provider)
	if err != nil {
		return err
	}
	token, err := api.outpostToken(ctx, outpost)
	if err != nil {
		return err
	}
	if err := runLDAPOutpost(ctx, out, s, p, token); err != nil {
		return err
	}
	fmt.Fprintf(out, "  authentik LDAP outpost ready — ldaps://%s:6636 (ldap on :3389)\n", s.DNS(n))
	return nil
}

// runLDAPOutpost launches the LDAP outpost container into the pod. It
// shares the pod's network namespace, so it reaches the core on
// localhost and serves 3389/6636 on the pod address. Left already-running
// alone; the token is stable across restarts and reset only by reinstall.
func runLDAPOutpost(ctx context.Context, out io.Writer, s service.Service, p *podman.Client, token string) error {
	container := s.Container() + "-ldap"
	if p.Running(ctx, container) {
		return nil
	}
	if !p.ImageExists(ctx, ldapImage) {
		fmt.Fprintf(out, "  Pulling %s…\n", ldapImage)
		if code, err := p.Pull(ctx, ldapImage); err != nil || code != 0 {
			return fmt.Errorf("pull %s failed", ldapImage)
		}
	}
	if p.Exists(ctx, container) {
		_, _ = p.Remove(ctx, container)
	}
	args := []string{"-d",
		"--pod", s.PodName(),
		"--name", container,
		"--restart", "no",
		"-e", "AUTHENTIK_HOST=http://localhost:9000",
		"-e", "AUTHENTIK_INSECURE=true",
		"-e", "AUTHENTIK_TOKEN=" + token,
		// The pod shares one netns; move the outpost's metrics port off
		// the server's 9300 (and the worker's 9301).
		"-e", "AUTHENTIK_LISTEN__METRICS=0.0.0.0:9302",
		"--label", "mpd.managed=true",
		"--label", "mpd.type=service",
		"--label", "mpd.name=" + s.Name + "-ldap",
		ldapImage,
	}
	if code, err := p.Run(ctx, args); err != nil || code != 0 {
		return fmt.Errorf("starting LDAP outpost container failed")
	}
	return nil
}

func (a *authentikAPI) flowBySlug(ctx context.Context, slug string) (string, error) {
	code, data, err := a.do(ctx, gohttp.MethodGet, "/api/v3/flows/instances/?slug="+slug, nil)
	if err != nil || code != 200 {
		return "", fmt.Errorf("looking up flow %s (HTTP %d)", slug, code)
	}
	r := results(data)
	if len(r) == 0 {
		return "", fmt.Errorf("flow %s not found", slug)
	}
	return str(r[0]["pk"]), nil
}

// ensureLDAPProvider returns the mpd-ldap provider's pk, creating it if
// absent.
func (a *authentikAPI) ensureLDAPProvider(ctx context.Context, authFlow, invFlow string) (float64, error) {
	code, data, err := a.do(ctx, gohttp.MethodGet, "/api/v3/providers/ldap/?name="+ldapProviderName, nil)
	if err != nil || code != 200 {
		return 0, fmt.Errorf("listing providers (HTTP %d)", code)
	}
	if p, ok := pick(results(data), "name", ldapProviderName); ok {
		return num(p["pk"]), nil
	}
	code, data, err = a.do(ctx, gohttp.MethodPost, "/api/v3/providers/ldap/", map[string]any{
		"name":               ldapProviderName,
		"authorization_flow": authFlow,
		"invalidation_flow":  invFlow,
		"base_dn":            ldapBaseDN,
	})
	if err != nil || code != 201 {
		return 0, fmt.Errorf("creating LDAP provider (HTTP %d): %s", code, data)
	}
	var obj map[string]any
	_ = json.Unmarshal(data, &obj)
	return num(obj["pk"]), nil
}

func (a *authentikAPI) ensureApplication(ctx context.Context, provider float64) error {
	code, data, err := a.do(ctx, gohttp.MethodGet, "/api/v3/core/applications/?slug="+ldapAppSlug, nil)
	if err != nil || code != 200 {
		return fmt.Errorf("listing applications (HTTP %d)", code)
	}
	if _, ok := pick(results(data), "slug", ldapAppSlug); ok {
		return nil
	}
	code, data, err = a.do(ctx, gohttp.MethodPost, "/api/v3/core/applications/", map[string]any{
		"name":     "mpd LDAP",
		"slug":     ldapAppSlug,
		"provider": provider,
	})
	if err != nil || code != 201 {
		return fmt.Errorf("creating application (HTTP %d): %s", code, data)
	}
	return nil
}

// ensureOutpost returns the mpd-ldap outpost object, creating it if
// absent. A created outpost brings its own service-account token.
func (a *authentikAPI) ensureOutpost(ctx context.Context, provider float64) (map[string]any, error) {
	code, data, err := a.do(ctx, gohttp.MethodGet, "/api/v3/outposts/instances/?name="+ldapOutpostName, nil)
	if err != nil || code != 200 {
		return nil, fmt.Errorf("listing outposts (HTTP %d)", code)
	}
	if o, ok := pick(results(data), "name", ldapOutpostName); ok {
		return o, nil
	}
	_, defData, err := a.do(ctx, gohttp.MethodGet, "/api/v3/outposts/instances/default_settings/", nil)
	if err != nil {
		return nil, err
	}
	var def struct {
		Config map[string]any `json:"config"`
	}
	_ = json.Unmarshal(defData, &def)
	if def.Config == nil {
		def.Config = map[string]any{}
	}
	def.Config["authentik_host"] = "http://localhost:9000"
	def.Config["authentik_host_insecure"] = true

	code, data, err = a.do(ctx, gohttp.MethodPost, "/api/v3/outposts/instances/", map[string]any{
		"name":      ldapOutpostName,
		"type":      "ldap",
		"providers": []float64{provider},
		"config":    def.Config,
	})
	if err != nil || code != 201 {
		return nil, fmt.Errorf("creating outpost (HTTP %d): %s", code, data)
	}
	var obj map[string]any
	_ = json.Unmarshal(data, &obj)
	return obj, nil
}

func (a *authentikAPI) outpostToken(ctx context.Context, outpost map[string]any) (string, error) {
	id := str(outpost["token_identifier"])
	if id == "" {
		return "", fmt.Errorf("outpost has no token identifier")
	}
	code, data, err := a.do(ctx, gohttp.MethodGet, "/api/v3/core/tokens/"+id+"/view_key/", nil)
	if err != nil || code != 200 {
		return "", fmt.Errorf("reading outpost token (HTTP %d)", code)
	}
	var obj map[string]any
	_ = json.Unmarshal(data, &obj)
	key := str(obj["key"])
	if key == "" {
		return "", fmt.Errorf("outpost token key was empty")
	}
	return key, nil
}

// ensureLDAPSCert mints an mpd-signed leaf for the direct LDAP hostname,
// uploads it as a certificate keypair, and assigns it to the provider so
// the outpost serves LDAPS with a browser-trusted cert. Renewal is by
// reinstall, so an existing keypair is left as-is.
func (a *authentikAPI) ensureLDAPSCert(ctx context.Context, out io.Writer, provider float64, n net.Net) error {
	host := n.Service("authentik")
	kpPK, ok, err := a.findCertKeypair(ctx)
	if err != nil {
		return err
	}
	if !ok {
		certPath := filepath.Join(cert.TempDir, "mpd-ldap-cert.pem")
		keyPath := filepath.Join(cert.TempDir, "mpd-ldap-key.pem")
		defer func() { os.Remove(certPath); os.Remove(keyPath) }()
		if err := cert.Generate(ctx, []string{host}, certPath, keyPath); err != nil {
			return err
		}
		certData, err := os.ReadFile(certPath)
		if err != nil {
			return err
		}
		keyData, err := os.ReadFile(keyPath)
		if err != nil {
			return err
		}
		code, data, err := a.do(ctx, gohttp.MethodPost, "/api/v3/crypto/certificatekeypairs/", map[string]any{
			"name":             ldapCertName,
			"certificate_data": string(certData),
			"key_data":         string(keyData),
		})
		if err != nil || code != 201 {
			return fmt.Errorf("uploading LDAPS cert (HTTP %d): %s", code, data)
		}
		var obj map[string]any
		_ = json.Unmarshal(data, &obj)
		kpPK = str(obj["pk"])
	}

	code, data, err := a.do(ctx, gohttp.MethodPatch, fmt.Sprintf("/api/v3/providers/ldap/%d/", int(provider)), map[string]any{
		"certificate":     kpPK,
		"tls_server_name": host,
	})
	if err != nil || code != 200 {
		return fmt.Errorf("assigning LDAPS cert to provider (HTTP %d): %s", code, data)
	}
	return nil
}

func (a *authentikAPI) findCertKeypair(ctx context.Context) (string, bool, error) {
	code, data, err := a.do(ctx, gohttp.MethodGet, "/api/v3/crypto/certificatekeypairs/?name="+ldapCertName, nil)
	if err != nil || code != 200 {
		return "", false, fmt.Errorf("listing certificate keypairs (HTTP %d)", code)
	}
	if kp, ok := pick(results(data), "name", ldapCertName); ok {
		return str(kp["pk"]), true, nil
	}
	return "", false, nil
}
