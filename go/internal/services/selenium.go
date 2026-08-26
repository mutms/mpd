package services

import "github.com/mutms/mpd/go/internal/service"

// selenium — Behat's WebDriver endpoint (standalone Chromium). A Moodle
// project with MPD_MOODLE_BEHAT=1 adds it to its required services, so mpd
// starts it on `mpd start`. The image is ~2 GB, so the first start announces
// the pull.
func init() {
	service.Register(service.Service{
		Name:      "selenium",
		HostOctet: 103,
		Image:     "docker.io/selenium/standalone-chromium:latest",
		Revision:  "1",
		Port:      4444,
		RunArgs: []string{
			"--shm-size=2g",
			"-e", "SE_NODE_MAX_SESSIONS=10",
			"-e", "SE_NODE_OVERRIDE_MAX_SESSIONS=true",
			"-e", "SE_SCREEN_WIDTH=1400",
			"-e", "SE_SCREEN_HEIGHT=800",
		},
	})
}
