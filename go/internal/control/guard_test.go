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
//
// The fake tree mirrors the real layout: php serves moodle, node serves
// astro, util serves bare and cftunnel.
func testGuard(t *testing.T, runtime string, projects ...state.Project) Guard {
	t.Helper()
	return Guard{
		Runtime: runtime,
		State:   testStore(t, projects...),
		Assets:  testAssets(t),
	}
}

// testAssets writes a fake assets tree: php serves moodle, node serves
// astro, util serves bare and cftunnel.
func testAssets(t *testing.T) assets.Tree {
	t.Helper()

	assetsDir := t.TempDir()
	for rt, types := range map[string][]string{
		"php":  {"moodle"},
		"node": {"astro"},
		"util": {"bare", "cftunnel"},
	} {
		base := filepath.Join(assetsDir, "runtimes", rt)
		if err := os.MkdirAll(base, 0o755); err != nil {
			t.Fatal(err)
		}
		// RuntimeNames counts a directory as a runtime when it has build.sh.
		if err := os.WriteFile(filepath.Join(base, "build.sh"), []byte("#!/bin/bash\n"), 0o755); err != nil {
			t.Fatal(err)
		}
		for _, ty := range types {
			dir := filepath.Join(base, "project_types", ty)
			if err := os.MkdirAll(dir, 0o755); err != nil {
				t.Fatal(err)
			}
			if err := os.WriteFile(filepath.Join(dir, "configuration.json"), []byte("{}\n"), 0o644); err != nil {
				t.Fatal(err)
			}
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
		"configure": true, "create": true, "delete": true,
		"help": true, "show": true, "start": true, "stop": true,
		// reset is project-scoped and needs VM privilege (drop the database,
		// privileged removal under /srv), so it is a verb a runtime cannot
		// perform for itself — and a corrupted database is something you
		// discover while working inside the runtime. Allowed, confined by the
		// scoping rule to the caller's own projects.
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
	g := testGuard(t, "php", state.Project{Name: "moodle45", RuntimeName: "php"})
	for _, verb := range AllowedVerbs() {
		if _, err := g.Check(Request{Argv: []string{verb, "moodle45"}, Cwd: "/srv"}); err != nil {
			t.Errorf("verb %q should be allowed, got: %v", verb, err)
		}
	}
}

func TestGlobalFlagsAndUnknownVerbsRefused(t *testing.T) {
	g := testGuard(t, "php")
	for _, argv := range [][]string{
		{"--vm-setup"},
		{"--runtime-delete=php"},
		{"--db-delete=mariadb-11-8"},
		{"--vm-stop"},
		{"list"},
		{"status"},
		{"nonsense"},
	} {
		if _, err := g.Check(Request{Argv: argv, Cwd: "/srv"}); err == nil {
			t.Errorf("%v should be refused from a runtime", argv)
		}
	}
}

// run must be refused even though it IS a project verb.
func TestRunIsRefusedWithGuidance(t *testing.T) {
	g := testGuard(t, "php")
	_, err := g.Check(Request{Argv: []string{"run", "php", "-v"}, Cwd: "/srv"})
	if err == nil {
		t.Fatal("run should be refused from inside a runtime")
	}
	if !strings.Contains(err.Error(), "already inside the runtime") {
		t.Errorf("error should explain why, got: %v", err)
	}
}

// A global flag smuggled in after a legitimate verb must not slip through.
func TestGlobalFlagAfterVerbRefused(t *testing.T) {
	g := testGuard(t, "php", state.Project{Name: "moodle45", RuntimeName: "php"})
	for _, argv := range [][]string{
		{"start", "moodle45", "--vm-stop"},
		{"create", "x", "--runtime-create=node"},
		{"show", "moodle45", "--db-delete=x"},
	} {
		if _, err := g.Check(Request{Argv: argv, Cwd: "/srv"}); err == nil {
			t.Errorf("%v should be refused", argv)
		}
	}
}

func TestForeignRuntimeProjectRefusedByName(t *testing.T) {
	g := testGuard(t, "php",
		state.Project{Name: "moodle45", RuntimeName: "php"},
		state.Project{Name: "site", RuntimeName: "node"},
	)
	_, err := g.Check(Request{Argv: []string{"delete", "site"}, Cwd: "/srv"})
	if err == nil {
		t.Fatal("acting on another runtime's project should be refused")
	}
	// The message must name both sides, or it is not actionable.
	for _, want := range []string{"site", "php", "node"} {
		if !strings.Contains(err.Error(), want) {
			t.Errorf("error should mention %q, got: %v", want, err)
		}
	}
}

// A scaffolded-but-unconfigured project has no runtimeName yet, so it must
// be judged by its type. Otherwise `configure` from the wrong runtime would
// provision another runtime — the thing the scoping rule exists to stop.
func TestUnconfiguredProjectJudgedByItsType(t *testing.T) {
	g := testGuard(t, "node",
		// No RuntimeName: exactly what `create` leaves behind.
		state.Project{Name: "moodle45", Type: "moodle"},
	)
	_, err := g.Check(Request{Argv: []string{"configure", "moodle45"}, Cwd: "/srv"})
	if err == nil {
		t.Fatal("configuring a moodle project from the node runtime should be refused")
	}
	for _, want := range []string{"moodle", "php", "node"} {
		if !strings.Contains(err.Error(), want) {
			t.Errorf("error should mention %q, got: %v", want, err)
		}
	}

	// Its own type is fine.
	own := testGuard(t, "node", state.Project{Name: "site", Type: "astro"})
	if _, err := own.Check(Request{Argv: []string{"configure", "site"}, Cwd: "/srv"}); err != nil {
		t.Errorf("configuring an astro project from node should be allowed, got: %v", err)
	}
}

// Same refusal via cwd inference rather than an explicit name.
func TestForeignRuntimeProjectRefusedByCwd(t *testing.T) {
	g := testGuard(t, "php",
		state.Project{Name: "site", RuntimeName: "node"},
	)
	_, err := g.Check(Request{Argv: []string{"start"}, Cwd: "/srv/projects/site/deep/inside"})
	if err == nil {
		t.Fatal("cwd inside another runtime's project should be refused")
	}
	if !strings.Contains(err.Error(), "node") {
		t.Errorf("error should name the owning runtime, got: %v", err)
	}
}

func TestOwnProjectAllowedByCwd(t *testing.T) {
	g := testGuard(t, "php", state.Project{Name: "moodle45", RuntimeName: "php"})
	if _, err := g.Check(Request{Argv: []string{"start"}, Cwd: "/srv/projects/moodle45/public"}); err != nil {
		t.Errorf("own project via cwd should be allowed, got: %v", err)
	}
}

// A malformed cwd means the peer is not mpd. Refused outright.
func TestMalformedCwdRefused(t *testing.T) {
	g := testGuard(t, "php")
	for _, cwd := range []string{
		"",                        // no working directory at all
		"relative/path",           // not absolute
		"/srv/projects/../../etc", // not lexically clean: reaches out of the tree
		"/srv/./projects",         // not lexically clean
	} {
		if _, err := g.Check(Request{Argv: []string{"show", "x"}, Cwd: cwd}); err == nil {
			t.Errorf("cwd %q should be refused as malformed", cwd)
		}
	}
}

// A cwd outside /srv is legitimate — you land in $HOME when you SSH in — but
// it cannot serve as context, because the same path on the VM is a different
// directory. The command still runs, from /srv.
func TestCwdOutsideSrvRunsFromSrv(t *testing.T) {
	g := testGuard(t, "php", state.Project{Name: "moodle45", RuntimeName: "php"})
	for _, cwd := range []string{"/home/skodak", "/etc", "/srvsomething", "/"} {
		decision, err := g.Check(Request{Argv: []string{"show", "moodle45"}, Cwd: cwd})
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
	g := testGuard(t, "php", state.Project{Name: "moodle45", RuntimeName: "php"})
	want := "/srv/projects/moodle45/public"
	decision, err := g.Check(Request{Argv: []string{"show"}, Cwd: want})
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
	g := testGuard(t, "php", state.Project{Name: "moodle45", RuntimeName: "php"})
	_, err := g.Check(Request{Argv: []string{"start"}, Cwd: "/home/skodak"})
	if err == nil {
		t.Fatal("a bare verb outside /srv should not resolve a project")
	}
	if !strings.Contains(err.Error(), "no project named") {
		t.Errorf("error should say no project was named, got: %v", err)
	}
}

// A cwd outside /srv must not be usable to reach another runtime's project
// either: the explicit name is still cross-checked.
func TestCwdOutsideSrvStillCrossChecksRuntime(t *testing.T) {
	g := testGuard(t, "php", state.Project{Name: "site", RuntimeName: "node"})
	if _, err := g.Check(Request{Argv: []string{"start", "site"}, Cwd: "/home/skodak"}); err == nil {
		t.Fatal("the runtime cross-check must apply regardless of cwd")
	}
}

func TestCreateTypeMustBelongToCallingRuntime(t *testing.T) {
	g := testGuard(t, "php")
	_, err := g.Check(Request{Argv: []string{"create", "thing", "--type=astro"}, Cwd: "/srv/projects/thing"})
	if err == nil {
		t.Fatal("a type from another runtime should be refused")
	}
	for _, want := range []string{"astro", "node", "php"} {
		if !strings.Contains(err.Error(), want) {
			t.Errorf("error should mention %q, got: %v", want, err)
		}
	}

	// The same type from its own runtime is fine, in both flag forms.
	node := testGuard(t, "node")
	for _, argv := range [][]string{
		{"create", "thing", "--type=astro"},
		{"create", "thing", "--type", "astro"},
	} {
		if _, err := node.Check(Request{Argv: argv, Cwd: "/srv/projects/thing"}); err != nil {
			t.Errorf("%v should be allowed from node, got: %v", argv, err)
		}
	}
}

// Name-based inference searches every runtime's types, so it can reach past
// the caller. It must be caught rather than silently retyped.
func TestCreateRefusesTypeInferredIntoAnotherRuntime(t *testing.T) {
	g := testGuard(t, "php")
	// "astro" matches the astro type exactly, which node owns.
	_, err := g.Check(Request{Argv: []string{"create", "astro"}, Cwd: "/srv/projects/astro"})
	if err == nil {
		t.Fatal("a name inferring another runtime's type should be refused")
	}
	if !strings.Contains(err.Error(), "node") {
		t.Errorf("error should name the owning runtime, got: %v", err)
	}
}

// One type means no ambiguity: fill it in rather than demanding the only
// possible answer.
func TestCreateFillsInTypeForSingleTypeRuntime(t *testing.T) {
	g := testGuard(t, "node")
	decision, err := g.Check(Request{Argv: []string{"create", "newthing"}, Cwd: "/srv/projects/newthing"})
	if err != nil {
		t.Fatalf("create in a single-type runtime should work without --type: %v", err)
	}
	if got := strings.Join(decision.Argv, " "); !strings.Contains(got, "--type=astro") {
		t.Errorf("guard should supply the runtime's only type, got %q", got)
	}
}

// Several types means the caller must choose — mpd's own fallback default
// could belong to another runtime entirely.
func TestCreateDemandsTypeForMultiTypeRuntime(t *testing.T) {
	g := testGuard(t, "util")
	_, err := g.Check(Request{Argv: []string{"create", "newthing"}, Cwd: "/srv/projects/newthing"})
	if err == nil {
		t.Fatal("a multi-type runtime should require --type")
	}
	for _, want := range []string{"bare", "cftunnel"} {
		if !strings.Contains(err.Error(), want) {
			t.Errorf("error should list %q as a choice, got: %v", want, err)
		}
	}
}

// Check must never mutate the caller's slice — the argv is reused.
func TestCheckDoesNotMutateRequestArgv(t *testing.T) {
	g := testGuard(t, "node")
	argv := []string{"create", "newthing"}
	original := strings.Join(argv, " ")
	if _, err := g.Check(Request{Argv: argv, Cwd: "/srv/projects/newthing"}); err != nil {
		t.Fatal(err)
	}
	if strings.Join(argv, " ") != original {
		t.Errorf("Check mutated the request argv: %v", argv)
	}
}

func TestConfigureSettingIsNotMistakenForProjectName(t *testing.T) {
	g := testGuard(t, "php", state.Project{Name: "moodle45", RuntimeName: "php"})
	// The project must come from cwd, not from the KEY=VALUE token.
	if _, err := g.Check(Request{
		Argv: []string{"configure", "MPD_DB=postgres:18"},
		Cwd:  "/srv/projects/moodle45",
	}); err != nil {
		t.Errorf("configure with only settings should resolve from cwd, got: %v", err)
	}
}

func TestMissingCallingRuntimeIsRefused(t *testing.T) {
	g := testGuard(t, "")
	if _, err := g.Check(Request{Argv: []string{"show", "x"}, Cwd: "/srv"}); err == nil {
		t.Fatal("a request with no calling runtime must be refused")
	}
}

func TestBareHelpAllowed(t *testing.T) {
	g := testGuard(t, "php")
	if _, err := g.Check(Request{Argv: []string{"help"}, Cwd: "/srv"}); err != nil {
		t.Errorf("bare help should be allowed, got: %v", err)
	}
}
