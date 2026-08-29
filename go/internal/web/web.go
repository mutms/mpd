// Package web serves mpd's status page on loopback, behind the VM's
// Caddy. The page is read-only: it renders state mpd already wrote.
// Do not add command execution, forms, API endpoints or input handling.
package web

import (
	"context"
	"embed"
	"errors"
	"fmt"
	"io"
	"io/fs"
	"net/http"
	"time"

	"github.com/mutms/mpd/go/internal/assets"
	"github.com/mutms/mpd/go/internal/current"
	"github.com/mutms/mpd/go/internal/net"
	"github.com/mutms/mpd/go/internal/podman"
	"github.com/mutms/mpd/go/internal/state"
	"github.com/mutms/mpd/go/internal/ui"
)

// Addr is where the server listens and where Caddy proxies to.
// Loopback, so nothing reaches it without crossing Caddy.
const Addr = "127.0.0.1:8099"

//go:embed static
var static embed.FS

// Deps is everything the page reads.
type Deps struct {
	Net      net.Net
	Podman   *podman.Client
	State    state.Store
	Observer current.Observer
	Assets   assets.Tree
	// Version is the mpd build version shown in the portal header.
	Version string
	// UnitActive reports whether a systemd unit is running; the bool is
	// true for a `systemctl --user` unit.
	UnitActive func(context.Context, string, bool) bool
}

// Serve runs the status server until ctx is cancelled. Blocking:
// systemd owns the lifecycle.
func Serve(ctx context.Context, out io.Writer, d Deps) error {
	mux := http.NewServeMux()

	// Every section renders standalone; the full page composes them.
	// That lets htmx refresh one card without touching the rest.
	for _, name := range []string{"projects", "services", "databases", "infra"} {
		section := name // captured per handler
		mux.HandleFunc("GET /section/"+section, func(w http.ResponseWriter, r *http.Request) {
			renderFragment(w, r, section, d)
		})
	}

	mux.HandleFunc("GET /{$}", func(w http.ResponseWriter, r *http.Request) {
		renderPage(w, r, d)
	})

	// fs.Sub strips the embed's own "static/" directory level; without
	// it every lookup 404s.
	assets, err := fs.Sub(static, "static")
	if err != nil {
		return err
	}
	mux.Handle("GET /static/", http.StripPrefix("/static/", http.FileServer(http.FS(assets))))

	server := &http.Server{
		Addr:              Addr,
		Handler:           mux,
		ReadHeaderTimeout: 5 * time.Second,
	}

	// Shut down on cancellation so the socket is released before the
	// next start.
	go func() {
		<-ctx.Done()
		shutdownCtx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		_ = server.Shutdown(shutdownCtx)
	}()

	ui.OK(out, "mpd web listening on http://%s (proxied at https://%s/)", Addr, d.Net.Zone())
	if err := server.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
		return err
	}
	return nil
}

func renderPage(w http.ResponseWriter, r *http.Request, d Deps) {
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	if err := page.Execute(w, pageData(r.Context(), d)); err != nil {
		// The header is already written; no status code left to send.
		fmt.Fprintf(w, "<!-- render error: %v -->", err)
	}
}

func renderFragment(w http.ResponseWriter, r *http.Request, name string, d Deps) {
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	if err := page.ExecuteTemplate(w, name, pageData(r.Context(), d)); err != nil {
		fmt.Fprintf(w, "<!-- render error: %v -->", err)
	}
}
