package services

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	gohttp "net/http"
	"time"

	"github.com/mutms/mpd/go/internal/net"
	"github.com/mutms/mpd/go/internal/podman"
	"github.com/mutms/mpd/go/internal/service"
)

// authentik provisioning, run as the service PostStart once the core is
// up. It configures what the core cannot configure for itself — the
// external base URL, then the LDAP outpost (see authentik_ldap.go). It is
// best-effort: a failure warns and returns nil, so the service still
// counts as started and the developer can re-run --service-start to
// retry. See docs/architecture.md.
func provisionAuthentik(ctx context.Context, out io.Writer, s service.Service, n net.Net, p *podman.Client) error {
	api := &authentikAPI{
		base:   fmt.Sprintf("http://%s:%d", s.IP(n), s.Port),
		token:  envDefault("MPD_AUTHENTIK_ADMIN_TOKEN", "mpd-authentik-dev-token"),
		client: &gohttp.Client{Timeout: 15 * time.Second},
	}

	if !api.waitReady(ctx, 120*time.Second) {
		fmt.Fprintln(out, "  authentik: core did not become ready; skipping (re-run --service-start=authentik to retry).")
		return nil
	}

	// authentik warns "The base URL has not been configured" until this
	// is set; point it at the frontdoor URL.
	if err := api.ensureBaseURL(ctx, "https://"+s.CaddyDNS(n)); err != nil {
		fmt.Fprintf(out, "  authentik: could not set base URL: %v\n", err)
	}

	if err := setupLDAP(ctx, out, api, s, n, p); err != nil {
		fmt.Fprintf(out, "  authentik LDAP: %v (re-run --service-start=authentik to retry).\n", err)
	}
	return nil
}

// ensureBaseURL sets the external base URL in authentik's system
// settings (idempotent). authentik stores it without a trailing slash.
func (a *authentikAPI) ensureBaseURL(ctx context.Context, url string) error {
	code, data, err := a.do(ctx, gohttp.MethodPatch, "/api/v3/admin/settings/", map[string]any{
		"base_url": url,
	})
	if err != nil {
		return err
	}
	if code != 200 {
		return fmt.Errorf("HTTP %d: %s", code, data)
	}
	return nil
}

// --- authentik API client (minimal, admin-token) --------------------

type authentikAPI struct {
	base   string
	token  string
	client *gohttp.Client
}

func (a *authentikAPI) do(ctx context.Context, method, path string, body any) (int, []byte, error) {
	var reader io.Reader
	if body != nil {
		buf, err := json.Marshal(body)
		if err != nil {
			return 0, nil, err
		}
		reader = bytes.NewReader(buf)
	}
	req, err := gohttp.NewRequestWithContext(ctx, method, a.base+path, reader)
	if err != nil {
		return 0, nil, err
	}
	req.Header.Set("Authorization", "Bearer "+a.token)
	req.Header.Set("Content-Type", "application/json")
	resp, err := a.client.Do(req)
	if err != nil {
		return 0, nil, err
	}
	defer resp.Body.Close()
	data, _ := io.ReadAll(resp.Body)
	return resp.StatusCode, data, nil
}

func (a *authentikAPI) waitReady(ctx context.Context, timeout time.Duration) bool {
	deadline := time.Now().Add(timeout)
	for time.Now().Before(deadline) {
		if code, _, err := a.do(ctx, gohttp.MethodGet, "/-/health/ready/", nil); err == nil && code == 200 {
			return true
		}
		select {
		case <-ctx.Done():
			return false
		case <-time.After(3 * time.Second):
		}
	}
	return false
}

// results decodes a paginated list response's results array.
func results(data []byte) []map[string]any {
	var page struct {
		Results []map[string]any `json:"results"`
	}
	_ = json.Unmarshal(data, &page)
	return page.Results
}

// pick finds the object whose field equals value. authentik's list
// endpoints do not all honour a `?field=` query filter (the outpost list
// ignores `?name=`), so the match is made here, never on results[0].
func pick(rs []map[string]any, field, value string) (map[string]any, bool) {
	for _, r := range rs {
		if str(r[field]) == value {
			return r, true
		}
	}
	return nil, false
}

// str renders a JSON value (string or number) as a string.
func str(v any) string {
	switch t := v.(type) {
	case string:
		return t
	case float64:
		return fmt.Sprintf("%v", t)
	default:
		return ""
	}
}

func num(v any) float64 {
	if f, ok := v.(float64); ok {
		return f
	}
	return 0
}
