package services

import "github.com/mutms/mpd/go/internal/service"

// mailpit — SMTP catch-all for every project. Mail is stored on a
// volume so the inbox survives an uninstall/start cycle.
func init() {
	service.Register(service.Service{
		Name:       "mailpit",
		HostOctet:  100,
		Image:      "docker.io/axllent/mailpit:latest",
		Revision:   "1",
		Volume:     "mpd-svc-mailpit",
		VolumePath: "/data",
		Port:       8025,
		RunArgs:    []string{"-e", "MP_DATABASE=/data/mailpit.db"},
	})
}
