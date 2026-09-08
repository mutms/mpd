package service

import (
	"context"
	"strings"
	"testing"

	"github.com/mutms/mpd/go/internal/exec"
	"github.com/mutms/mpd/go/internal/net"
	"github.com/mutms/mpd/go/internal/podman"
)

func podService() Service {
	return Service{
		Name:      "zitadel",
		HostOctet: net.ServiceHostFirst + 1,
		Revision:  "1",
		Port:      9000,
		PodContainers: []PodContainer{
			{Suffix: "postgres", Image: "postgres:16", Volume: "mpd-svc-zitadel-db", VolumePath: "/data",
				RunArgs: []string{"-e", "POSTGRES_DB=zitadel"}},
			{Suffix: "server", Primary: true, Image: "zitadel:latest", Args: []string{"server"}},
		},
	}
}

func recorder() (*podman.Client, *[][]string) {
	var calls [][]string
	c := podman.NewWith(func(ctx context.Context, args []string) (exec.Result, error) {
		calls = append(calls, args)
		return exec.Result{Code: 0}, nil
	})
	return c, &calls
}

func TestPodHelpers(t *testing.T) {
	s := podService()
	if !s.IsPod() {
		t.Fatal("IsPod = false, want true for a service with PodContainers")
	}
	if got := s.PodName(); got != "mpd-svc-zitadel" {
		t.Errorf("PodName = %q", got)
	}
	if got := s.memberName(s.PodContainers[0]); got != "mpd-svc-zitadel-postgres" {
		t.Errorf("memberName = %q", got)
	}
	vols := s.Volumes()
	if len(vols) != 1 || vols[0] != "mpd-svc-zitadel-db" {
		t.Errorf("Volumes = %v, want [mpd-svc-zitadel-db]", vols)
	}

	// A single-container service is not a pod.
	if (Service{Name: "mailpit", HostOctet: net.ServiceHostFirst}).IsPod() {
		t.Error("single-container service reported IsPod")
	}
}

func TestCreatePodArgs(t *testing.T) {
	s := podService()
	n, err := net.New(150)
	if err != nil {
		t.Fatalf("net.New: %v", err)
	}
	p, calls := recorder()

	if err := createPod(context.Background(), s, n, p); err != nil {
		t.Fatalf("createPod: %v", err)
	}
	if len(*calls) != 3 { // pod create + 2 containers
		t.Fatalf("got %d podman calls, want 3:\n%v", len(*calls), *calls)
	}

	podCreate := strings.Join((*calls)[0], " ")
	for _, want := range []string{
		"pod create", "--name mpd-svc-zitadel",
		"--network mpd-internal:ip=" + s.IP(n),
		RevisionLabel + "=1", "--dns",
	} {
		if !strings.Contains(podCreate, want) {
			t.Errorf("pod create %q missing %q", podCreate, want)
		}
	}

	pg := strings.Join((*calls)[1], " ")
	for _, want := range []string{
		"run -d --pod mpd-svc-zitadel", "--name mpd-svc-zitadel-postgres",
		"--restart always", "-v mpd-svc-zitadel-db:/data",
		"mpd.name=zitadel-postgres", // helper is suffixed, not the service name
		"POSTGRES_DB=zitadel", "postgres:16",
	} {
		if !strings.Contains(pg, want) {
			t.Errorf("postgres run %q missing %q", pg, want)
		}
	}

	server := strings.Join((*calls)[2], " ")
	for _, want := range []string{
		"--name mpd-svc-zitadel-server", "zitadel:latest server",
	} {
		if !strings.Contains(server, want) {
			t.Errorf("server run %q missing %q", server, want)
		}
	}
	// The primary must carry the canonical label, not a suffixed one.
	if !strings.Contains(server, "--label mpd.name=zitadel ") {
		t.Errorf("server run %q should carry mpd.name=zitadel", server)
	}
	// Network/DNS flags must be on the pod, never on a member container.
	if strings.Contains(server, "--network") || strings.Contains(pg, "--dns") {
		t.Error("member containers must not carry --network/--dns; those go on the pod")
	}
}
