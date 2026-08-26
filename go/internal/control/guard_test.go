package control

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/mutms/mpd/go/internal/assets"
	"github.com/mutms/mpd/go/internal/cli"
	"github.com/mutms/mpd/go/internal/state"
)

// testGuard builds a Guard over a fake assets tree and state dir.
func testGuard(t *testing.T, runtime string, projects ...state.Project) Guard {
	t.Helper()
	return Guard{
		Runtime: runtime,
		State:   testStore(t, projects...),
		Assets:  testAssets(t),
	}
}

// testAssets writes a fake assets tree mirroring the real layout: the
// unified runtime serving moodle and astro.
func testAssets(t *testing.T) assets.Tree {
	t.Helper()

	assetsDir := t.TempDir()
	for _, ty := range []string{"moodle", "astro"} {
		dir := filepath.Join(assetsDir, "runtime", "project_types", ty)
		if err := os.MkdirAll(dir, 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(filepath.Join(dir, "configuration.json"), []byte("{}\n"), 0o644); err != nil {
			t.Fatal(err)
		}
	}

	return assets.NewAt(assetsDir)
}

// testStore writes a state directory holding the given projects.
func testStore(t *testing.T, projects ...state.Project) state.Store {
	t.Helper()

	stateDir := t.TempDir()
	if len(projects) > 0 {
		body, err := json.Marshal(struct {
			Projects []state.Project `json:"projects"`
		}{projects})
		if err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(filepath.Join(stateDir, "projects.json"), body, 0o644); err != nil {
			t.Fatal(err)
		}
	}
	return state.NewAt(stateDir)
}

// The allowlist must track cli.ProjectVerbs, minus the ones blocked here.
// If this fails because a verb was added, decide deliberately whether a
// runtime should reach it — do not just update the expectation.
func TestAllowedVerbsTracksProjectVerbs(t *testing.T) {
	want := map[string]bool{
		"init": true, "delete": true,
		"help": true, "status": true, "start": true, "stop": true,
		// reset is project-scoped and needs VM privilege (drop the database,
		// privileged removal under /srv), so it is a verb a runtime cannot
		// perform for itself — and a corrupted database is something you
		// discover while working inside the runtime. Allowed.
		"reset": true,
		"run":   false, // loops back into the calling runtime
	}

	if len(cli.ProjectVerbs) != len(want) {
		t.Fatalf("cli.ProjectVerbs is %v (%d verbs), but this test knows %d.\n"+
			"A verb was added or removed: decide whether it should be reachable "+
			"from inside a runtime, then update blockedVerbs and this map.",
			cli.ProjectVerbs, len(cli.ProjectVerbs), len(want))
	}

	allowed := map[string]bool{}
	for _, v := range AllowedVerbs() {
		allowed[v] = true
	}
	for verb, shouldAllow := range want {
		if allowed[verb] != shouldAllow {
			t.Errorf("verb %q: allowed=%v, want %v", verb, allowed[verb], shouldAllow)
		}
	}
}

func TestEveryAllowedVerbPasses(t *testing.T) {
	g := testGuard(t, "runtime", state.Project{Name: "moodle45", RuntimeName: "runtime"})
	for _, verb := range AllowedVerbs() {
		if _, err := g.Check(Request{Argv: []string{verb, "moodle45"}, Cwd: "/srv"}); err != nil {
			t.Errorf("verb %q should be allowed, got: %v", verb, err)
		}
	}
}

// Every flag on the denylist is refused, in either flag form.
func TestBlockedFlagsRefused(t *testing.T) {
	g := testGuard(t, "runtime")
	for _, argv := range [][]string{
		{"--vm-setup"},
		{"--vm-upgrade"},
		{"--vm-start"},
		{"--vm-stop"},
		{"--vm-restart"},
		{"--runtime-rebuild"},
		{"--runtime-restore"},
		{"--web"},
		{"--control"},
		{"--vm-stop=1"}, // =value form must match the same key
	} {
		if _, err := g.Check(Request{Argv: argv, Cwd: "/srv"}); err == nil {
			t.Errorf("%v should be refused from a runtime", argv)
		}
	}
}

// The denylist inversion opened db/service management, --runtime-backup
// and list/version to the runtime; the guard must let them through (the
// child owns the actual argument handling). An unknown token also passes
// the guard — the child produces the canonical "unknown command" error,
// not a second differently-worded one here.
func TestNewlyAllowedCommandsPass(t *testing.T) {
	g := testGuard(t, "runtime")
	for _, argv := range [][]string{
		{"--db-create", "postgres:18"},
		{"--db-delete=mariadb-11-8"},
		{"--service-start", "mailpit"},
		{"--service-purge=mailpit"},
		{"--runtime-backup"},
		{"--vm-status"}, // read-only, allowed
		{"list"},
		{"nonsense"},
	} {
		if _, err := g.Check(Request{Argv: argv, Cwd: "/srv"}); err != nil {
			t.Errorf("%v should pass the guard, got: %v", argv, err)
		}
	}
}

// Every global flag must be either denied or explicitly allowed from a
// runtime — never unclassified. This is the safe-by-default pin: adding a
// flag to cli.GlobalFlags without a decision here fails the build.
func TestEveryGlobalFlagClassified(t *testing.T) {
	allowedFromRuntime := map[string]bool{
		"--runtime-backup":    true,
		"--runtime-upgrade":   true, // apt + re-configure inside the caller's own runtime
		"--service-start":     true,
		"--service-stop":      true,
		"--service-uninstall": true,
		"--service-purge":     true,
		"--db-create":         true,
		"--db-start":          true,
		"--db-stop":           true,
		"--db-delete":         true,
		"--vm-status":         true, // read-only
		"--vm-diag":           true, // read-only probes; useful from inside a runtime
		"--yes":               true, // modifier, not an action
		"--debug":             true, // modifier, not an action
		"--help":              true, // modifier, not an action
	}
	for _, flag := range cli.GlobalFlags {
		_, blocked := blockedFlags[flag]
		// Exactly one of the two must hold. Both-false is unclassified
		// (a new flag); both-true is a contradiction.
		if blocked == allowedFromRuntime[flag] {
			t.Errorf("global flag %q is not classified exactly once: "+
				"put it in blockedFlags or this test's allowed set.\n"+
				"A flag was added — decide whether a runtime may reach it.", flag)
		}
	}
}

// run must be refused even though it IS a project verb.
func TestRunIsRefusedWithGuidance(t *testing.T) {
	g := testGuard(t, "runtime")
	_, err := g.Check(Request{Argv: []string{"run", "php", "-v"}, Cwd: "/srv"})
	if err == nil {
		t.Fatal("run should be refused from inside a runtime")
	}
	if !strings.Contains(err.Error(), "already inside the runtime") {
		t.Errorf("error should explain why, got: %v", err)
	}
}

// A blocked flag smuggled in after a legitimate verb must not slip
// through — the scan covers the whole argv, not just the first token.
func TestBlockedFlagAfterVerbRefused(t *testing.T) {
	g := testGuard(t, "runtime", state.Project{Name: "moodle45", RuntimeName: "runtime"})
	for _, argv := range [][]string{
		{"start", "moodle45", "--vm-stop"},
		{"init", "x", "--runtime-rebuild"},
		{"status", "moodle45", "--control"},
		{"start", "moodle45", "--vm-setup"},
	} {
		if _, err := g.Check(Request{Argv: argv, Cwd: "/srv"}); err == nil {
			t.Errorf("%v should be refused", argv)
		}
	}
}

// A malformed cwd means the peer is not mpd. Refused outright.
func TestMalformedCwdRefused(t *testing.T) {
	g := testGuard(t, "runtime")
	for _, cwd := range []string{
		"",                        // no working directory at all
		"relative/path",           // not absolute
		"/srv/projects/../../etc", // not lexically clean: reaches out of the tree
		"/srv/./projects",         // not lexically clean
	} {
		if _, err := g.Check(Request{Argv: []string{"status", "x"}, Cwd: cwd}); err == nil {
			t.Errorf("cwd %q should be refused as malformed", cwd)
		}
	}
}

// A cwd outside /srv is legitimate — you land in $HOME when you SSH in — but
// it cannot serve as context, because the same path on the VM is a different
// directory. The command still runs, from /srv.
func TestCwdOutsideSrvRunsFromSrv(t *testing.T) {
	g := testGuard(t, "runtime", state.Project{Name: "moodle45", RuntimeName: "runtime"})
	for _, cwd := range []string{"/home/skodak", "/etc", "/srvsomething", "/"} {
		decision, err := g.Check(Request{Argv: []string{"status", "moodle45"}, Cwd: cwd})
		if err != nil {
			t.Errorf("cwd %q with an explicit project should work, got: %v", cwd, err)
			continue
		}
		if decision.Dir != "/srv" {
			t.Errorf("cwd %q: child should run in /srv, got %q", cwd, decision.Dir)
		}
	}
}

// Inside /srv, the caller's own directory is preserved — that is what makes
// project inference and relative paths behave as they do on the VM.
func TestCwdInsideSrvIsPreserved(t *testing.T) {
	g := testGuard(t, "runtime", state.Project{Name: "moodle45", RuntimeName: "runtime"})
	want := "/srv/projects/moodle45/public"
	decision, err := g.Check(Request{Argv: []string{"status"}, Cwd: want})
	if err != nil {
		t.Fatal(err)
	}
	if decision.Dir != want {
		t.Errorf("child dir = %q, want the caller's own %q", decision.Dir, want)
	}
}

// Outside /srv there is nothing to infer from, so a verb that needs a
// project must be told which one.
func TestCwdOutsideSrvCannotInferProject(t *testing.T) {
	g := testGuard(t, "runtime", state.Project{Name: "moodle45", RuntimeName: "runtime"})
	_, err := g.Check(Request{Argv: []string{"start"}, Cwd: "/home/skodak"})
	if err == nil {
		t.Fatal("a bare verb outside /srv should not resolve a project")
	}
	if !strings.Contains(err.Error(), "no project named") {
		t.Errorf("error should say no project was named, got: %v", err)
	}
}

// Own projects are reachable by cwd inference.
func TestOwnProjectAllowedByCwd(t *testing.T) {
	g := testGuard(t, "runtime", state.Project{Name: "moodle45", RuntimeName: "runtime"})
	if _, err := g.Check(Request{Argv: []string{"start"}, Cwd: "/srv/projects/moodle45/public"}); err != nil {
		t.Errorf("own project via cwd should be allowed, got: %v", err)
	}
}

// A declared --type must exist in the assets tree, in both flag forms.
func TestInitValidatesDeclaredType(t *testing.T) {
	g := testGuard(t, "runtime")
	_, err := g.Check(Request{Argv: []string{"init", "thing", "--type=rails"}, Cwd: "/srv/projects/thing"})
	if err == nil {
		t.Fatal("an unknown type should be refused")
	}
	for _, want := range []string{"rails", "moodle", "astro"} {
		if !strings.Contains(err.Error(), want) {
			t.Errorf("error should mention %q, got: %v", want, err)
		}
	}

	for _, argv := range [][]string{
		{"init", "thing", "--type=astro"},
		{"init", "thing", "--type", "astro"},
		{"init", "thing", "--type=moodle"},
	} {
		if _, err := g.Check(Request{Argv: argv, Cwd: "/srv/projects/thing"}); err != nil {
			t.Errorf("%v should be allowed, got: %v", argv, err)
		}
	}
}

// Without --type the child's own inference and default apply — the guard
// passes the argv through untouched.
func TestInitWithoutTypePassesThrough(t *testing.T) {
	g := testGuard(t, "runtime")
	decision, err := g.Check(Request{Argv: []string{"init", "newthing"}, Cwd: "/srv/projects/newthing"})
	if err != nil {
		t.Fatalf("init without --type should pass through: %v", err)
	}
	if got := strings.Join(decision.Argv, " "); got != "init newthing" {
		t.Errorf("argv should be untouched, got %q", got)
	}
}

// Check must never mutate the caller's slice — the argv is reused.
func TestCheckDoesNotMutateRequestArgv(t *testing.T) {
	g := testGuard(t, "runtime")
	argv := []string{"init", "newthing"}
	original := strings.Join(argv, " ")
	if _, err := g.Check(Request{Argv: argv, Cwd: "/srv/projects/newthing"}); err != nil {
		t.Fatal(err)
	}
	if strings.Join(argv, " ") != original {
		t.Errorf("Check mutated the request argv: %v", argv)
	}
}

func TestStartSettingIsNotMistakenForProjectName(t *testing.T) {
	g := testGuard(t, "runtime", state.Project{Name: "moodle45", RuntimeName: "runtime"})
	// The project must come from cwd, not from the KEY=VALUE token.
	if _, err := g.Check(Request{
		Argv: []string{"start", "MPD_DB=postgres:18"},
		Cwd:  "/srv/projects/moodle45",
	}); err != nil {
		t.Errorf("start with only settings should resolve from cwd, got: %v", err)
	}
}

func TestMissingCallingRuntimeIsRefused(t *testing.T) {
	g := testGuard(t, "")
	if _, err := g.Check(Request{Argv: []string{"status", "x"}, Cwd: "/srv"}); err == nil {
		t.Fatal("a request with no calling runtime must be refused")
	}
}

func TestBareHelpAllowed(t *testing.T) {
	g := testGuard(t, "runtime")
	if _, err := g.Check(Request{Argv: []string{"help"}, Cwd: "/srv"}); err != nil {
		t.Errorf("bare help should be allowed, got: %v", err)
	}
}
