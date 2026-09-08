package services

import "github.com/mutms/mpd/go/internal/service"

// mailpit — SMTP catch-all for every project. Mail is stored on a
// volume so the inbox survives an uninstall/start cycle. The web UI is
// fronted over HTTPS at mailpit.caddy.<zone>; SMTP stays direct at
// mailpit.svc.<zone>:1025.
func init() {
	service.Register(service.Service{
		Name:       "mailpit",
		HostOctet:  100,
		Image:      "docker.io/axllent/mailpit:latest",
		Revision:   "1",
		Volume:     "mpd-svc-mailpit",
		VolumePath: "/data",
		Port:       8025,
		TLS:        true,
		RunArgs:    []string{"-e", "MP_DATABASE=/data/mailpit.db"},
	})
}
