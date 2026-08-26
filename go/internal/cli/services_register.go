package cli

// The cli layer pulls in the concrete services once, for their init()
// registrations — the same way it would import a backends-style impls package.
// Every command that lists or drives a service reaches them through the
// service framework registry; without this blank import that registry is
// empty. main.go imports cli, so the binary is covered, and so are cli's own
// tests.
import _ "github.com/mutms/mpd/go/internal/services"
