// Package web serves mpd's status page.
//
// It listens on loopback only. TLS, the hostname and any future access
// control belong to the VM's Caddy, which reverse-proxies here — so this
// server holds no certificate, binds no privileged port, and cannot be
// reached from outside the VM except through that proxy.
//
// SECURITY: the page is READ-ONLY. It renders what mpd has already
// written to the state directory and the data volume. Do not add command
// execution, form handling, API endpoints or user input processing. If
// the portal ever gains a password, that changes who may look — not what
// the page is allowed to do.
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
//
// Loopback, so nothing reaches it without crossing Caddy; a high port, so
// the process needs no privileges and can run as an ordinary user unit.
const Addr = "127.0.0.1:8099"

//go:embed static
var static embed.FS

// Deps is everything the page reads. All of it is data mpd already holds
// in typed form — the page re-parses nothing.
type Deps struct {
	Net      net.Net
	Podman   *podman.Client
	State    state.Store
	Observer current.Observer
	Assets   assets.Tree
	// UnitActive reports whether a systemd-backed service is running,
	// injected so rendering never shells out on its own. The bool is the
	// unit's scope — true for a `systemctl --user` unit.
	UnitActive func(context.Context, string, bool) bool
}

// Serve runs the status server until ctx is cancelled.
//
// Foreground and blocking: systemd owns the lifecycle (Type=simple,
// Restart=always), so there is nothing to daemonise here.
func Serve(ctx context.Context, out io.Writer, d Deps) error {
	mux := http.NewServeMux()

	// Fragment-first: every section renders standalone, and the full page
	// is the sections composed. That is what lets htmx refresh one card
	// without touching the rest — and it is why an open popover survives
	// a refresh, rather than being restored afterwards from the URL hash
	// the way the PHP portal had to.
	for _, name := range []string{"projects", "runtimes", "databases", "infra", "services"} {
		section := name // captured per handler
		mux.HandleFunc("GET /section/"+section, func(w http.ResponseWriter, r *http.Request) {
			renderFragment(w, r, section, d)
		})
	}

	mux.HandleFunc("GET /{$}", func(w http.ResponseWriter, r *http.Request) {
		renderPage(w, r, d)
	})

	// fs.Sub strips the embed's own directory level: without it the
	// handler looks for "htmx.min.js" in an FS whose only entry is
	// "static/htmx.min.js", and serves a 404 that looks like a routing
	// bug rather than a path bug.
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

	// Shut down on cancellation rather than letting systemd SIGKILL us:
	// an in-flight render is cheap to finish and the socket is then
	// released before the next start.
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
		// The header is already written by then, so there is no status
		// code left to send — log-shaped output is all that is useful.
		fmt.Fprintf(w, "<!-- render error: %v -->", err)
	}
}

func renderFragment(w http.ResponseWriter, r *http.Request, name string, d Deps) {
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	if err := page.ExecuteTemplate(w, name, pageData(r.Context(), d)); err != nil {
		fmt.Fprintf(w, "<!-- render error: %v -->", err)
	}
}
