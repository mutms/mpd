package service

import (
	"testing"

	"github.com/mutms/mpd/go/internal/net"
)

// Registry mechanics, tested against a fresh registry: the concrete
// services are not imported here, so each test seeds what it needs.
// A panicking Register never appends, so reject tests leave it clean.

func mustPanic(t *testing.T, want string, fn func()) {
	t.Helper()
	defer func() {
		if recover() == nil {
			t.Errorf("%s: expected a panic, got none", want)
		}
	}()
	fn()
}

func TestRegisterRejectsOutOfRangeOctet(t *testing.T) {
	mustPanic(t, "octet below the range", func() {
		Register(Service{Name: "below", HostOctet: net.ServiceHostFirst - 1})
	})
	mustPanic(t, "octet above the range", func() {
		Register(Service{Name: "above", HostOctet: net.ServiceHostLast + 1})
	})
}

func TestRegisterRejectsDuplicates(t *testing.T) {
	Register(Service{Name: "one", HostOctet: net.ServiceHostFirst})
	mustPanic(t, "duplicate name", func() {
		Register(Service{Name: "one", HostOctet: net.ServiceHostFirst + 1})
	})
	mustPanic(t, "duplicate octet", func() {
		Register(Service{Name: "two", HostOctet: net.ServiceHostFirst})
	})
}

func TestAllSortsByOctet(t *testing.T) {
	// Registered out of address order; All must return them by HostOctet.
	Register(Service{Name: "high", HostOctet: net.ServiceHostFirst + 5})
	Register(Service{Name: "low", HostOctet: net.ServiceHostFirst + 3})
	all := All()
	for i := 1; i < len(all); i++ {
		if all[i-1].HostOctet > all[i].HostOctet {
			t.Fatalf("All() not sorted by octet: %d before %d",
				all[i-1].HostOctet, all[i].HostOctet)
		}
	}
}
