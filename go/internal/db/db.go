// Package db manages the database containers projects connect to.
//
// One container per engine:version, shared by every project that asks
// for it — mpd does not run a database per project. Containers are named
// mpd-db-<databaseId>, where databaseId is the engine and version with
// dots replaced by dashes, so the name survives round-tripping back into
// an engine and version.
package db

import (
	"context"
	"fmt"
	"io"
	"sort"
	"strings"
	"time"

	"github.com/mutms/mpd/go/internal/net"
	"github.com/mutms/mpd/go/internal/podman"
	"github.com/mutms/mpd/go/internal/srv"
	"github.com/mutms/mpd/go/internal/state"
)

// Engines mpd knows how to run. Anything else is refused rather than
// passed through to podman, so a typo fails with a list instead of an
// image pull.
var Engines = []string{"postgres", "mariadb", "mysql"}

// Ref identifies one database container.
type Ref struct {
	Engine    string
	Version   string
	ID        string // databaseId: engine-version, dots → dashes
	Container string // mpd-db-<ID>
}

// ShortName builds the databaseId for an engine and version.
// e.g. ("mariadb", "10.1.1") → "mariadb-10-1-1".
func ShortName(engine, version string) string {
	return engine + "-" + strings.ReplaceAll(version, ".", "-")
}

// ContainerName builds the container name for an engine and version.
func ContainerName(engine, version string) string {
	return "mpd-db-" + ShortName(engine, version)
}

// ParseTag validates an MPD_DB tag without touching podman, for CLI
// argument checking. Same rules as Resolve's engine:version form.
func ParseTag(raw string) (engine, version string, err error) {
	engine, version, found := strings.Cut(raw, ":")
	if !found {
		version = "latest"
	}
	if !knownEngine(engine) {
		return "", "", unknownEngine(engine)
	}
	if version != "latest" {
		if version == "" || version[0] < '0' || version[0] > '9' {
			return "", "", fmt.Errorf(
				"Invalid version '%s' for '%s'. Must be 'latest' or start with a digit "+
					"(e.g. 17, 17.2, 17-bookworm).", version, engine)
		}
	}
	return engine, version, nil
}

// Resolve turns user input into a Ref. Accepted forms:
//
//	postgres          bare engine → :latest, matching Docker convention
//	postgres:17       engine:version
//	postgres-17       databaseId (as printed by `mpd list dbs`)
//
// Anything else is looked up as an existing container by name, so a
// container adopted from an older naming scheme can still be addressed.
func Resolve(ctx context.Context, input string, p *podman.Client) (Ref, error) {
	if engine, version, found := strings.Cut(input, ":"); found {
		if !knownEngine(engine) {
			return Ref{}, unknownEngine(engine)
		}
		return newRef(engine, version), nil
	}

	if knownEngine(input) {
		return newRef(input, "latest"), nil
	}

	for _, engine := range Engines {
		if strings.HasPrefix(input, engine+"-") {
			versionPart := strings.TrimPrefix(input, engine+"-")
			if versionPart == "" {
				return Ref{}, fmt.Errorf("Invalid database id '%s'.", input)
			}
			return newRef(engine, strings.ReplaceAll(versionPart, "-", ".")), nil
		}
	}

	container := "mpd-db-" + input
	if !p.Exists(ctx, container) {
		return Ref{}, fmt.Errorf(
			"DB container 'mpd-db-%s' not found. Use engine:version or databaseId format.", input)
	}
	engine := p.Label(ctx, container, "mpd.db.engine")
	if engine == "" {
		return Ref{}, fmt.Errorf("Could not read engine label from container 'mpd-db-%s'.", input)
	}
	version := p.Label(ctx, container, "mpd.db.version")
	return Ref{Engine: engine, Version: version, ID: input, Container: container}, nil
}

func newRef(engine, version string) Ref {
	return Ref{
		Engine:    engine,
		Version:   version,
		ID:        ShortName(engine, version),
		Container: ContainerName(engine, version),
	}
}

func knownEngine(name string) bool {
	for _, e := range Engines {
		if e == name {
			return true
		}
	}
	return false
}

func unknownEngine(name string) error {
	return fmt.Errorf("Unknown engine '%s'. Valid values: %s", name, strings.Join(Engines, ", "))
}

// WaitFor blocks until the container accepts connections, up to ~60s.
//
// The probe goes over TCP to 127.0.0.1, never the unix socket, and that
// is the whole point of it. On a first run both official entrypoints
// bring up a *temporary* server to initialise the data directory and set
// the root credentials, and they deliberately keep it off the network —
// mariadb/mysql with `--skip-networking`, postgres with
// `listen_addresses=”`. A socket probe is answered by that temporary
// server, so it reports ready, the entrypoint then stops it to start the
// real one, and whatever mpd does next races the gap. TCP is closed for
// exactly that window, which makes it the only probe that means "the
// server users will connect to is up".
//
// The client is engine-specific and not interchangeable: MariaDB 12.x
// dropped the `mysql` CLI symlink, so the two MySQL-family engines no
// longer share a binary.
func WaitFor(ctx context.Context, ref Ref, p *podman.Client, out interface{ Write([]byte) (int, error) }) error {
	interval := 2 * time.Second
	if ref.Engine == "postgres" {
		interval = time.Second
	}
	for i := 0; i < 30; i++ {
		var code int
		switch ref.Engine {
		case "postgres":
			code = p.ExecQuietly(ctx, ref.Container, "pg_isready", "-h", "127.0.0.1", "-U", "postgres")
		case "mariadb":
			code = p.ExecQuietly(ctx, ref.Container,
				"mariadb", "-h", "127.0.0.1", "-u", "root", "-proot", "-e", "SELECT 1")
		default:
			code = p.ExecQuietly(ctx, ref.Container,
				"mysql", "-h", "127.0.0.1", "-u", "root", "-proot", "-e", "SELECT 1")
		}
		if code == 0 {
			return nil
		}
		// Announced on the first miss rather than up front: Ensure probes
		// every time now, and a ready container should say nothing.
		if i == 0 {
			fmt.Fprintf(out, "Waiting for %s to be ready...\n", ref.Container)
		}
		time.Sleep(interval)
	}
	return fmt.Errorf("%s did not become ready within 60s.", ref.Container)
}

// RebuildStateCache rewrites databases.json from what podman reports.
//
// The containers are the truth; databases.json is a cache for readers
// without podman access (the portal, in-runtime tools). Entries missing
// any identifying label are skipped rather than guessed at — a
// half-labelled container is not a database mpd manages.
func RebuildStateCache(ctx context.Context, p *podman.Client, s state.Store) error {
	var entries []state.Database
	for _, item := range p.Ps(ctx, "label=mpd.type=db") {
		id := item.Label("mpd.name")
		engine := item.Label("mpd.db.engine")
		version := item.Label("mpd.db.version")
		if id == "" || engine == "" || version == "" {
			continue
		}
		container := item.Name()
		if container == "" {
			container = "mpd-db-" + id
		}
		status := "stopped"
		if item.State == "running" {
			status = "running"
		}
		entries = append(entries, state.Database{
			DatabaseID:    id,
			Engine:        engine,
			Version:       version,
			ContainerName: container,
			Status:        status,
		})
	}
	sort.Slice(entries, func(i, j int) bool { return entries[i].DatabaseID < entries[j].DatabaseID })
	return s.SaveDatabases(entries)
}

// AllocateIP returns the lowest free address in the DB range of this
// VM's /24.
//
// Addresses are pinned at create time via `--network mpd-internal:ip=`,
// so once allocated they stay stable for the container's lifetime;
// slots freed by delete are reusable. Only addresses inside *this* VM's
// subnet count as taken — a container left over from another subnet must
// not consume a slot.
func AllocateIP(ctx context.Context, p *podman.Client, n net.Net) (string, error) {
	used := map[int]bool{}
	for _, item := range p.Ps(ctx, "label=mpd.type=db") {
		// Prefer the explicit label set at create time; fall back to the
		// live address for containers predating that scheme.
		addr := item.Label("mpd.ip")
		if addr == "" {
			addr = p.ContainerIP(ctx, item.Name(), "mpd-internal")
		}
		if host, ok := n.HostOctet(addr); ok {
			used[host] = true
		}
	}
	for host := net.DBHostFirst; host <= net.DBHostLast; host++ {
		if !used[host] {
			return n.IP(host), nil
		}
	}
	return "", fmt.Errorf("DB IP pool exhausted (%s–%d). Delete unused DB containers first.",
		n.IP(net.DBHostFirst), net.DBHostLast)
}

// DataDir is where an engine keeps its files on the shared data volume.
func DataDir(engine, version string) string {
	return "/srv/dbs/" + ShortName(engine, version)
}

// image is the upstream image reference for an engine and version.
func image(engine, version string) string {
	return "docker.io/library/" + engine + ":" + version
}

// runArgs builds the `podman run` arguments for a new DB container.
//
// The engine-specific flags are dev-tuned and not production-safe, but
// the line is drawn at corruption: postgres runs with
// synchronous_commit=off (lose the last moments of work on a crash) and
// NOT full_page_writes=off (which risks an unrepairable torn page). See
// docs/SECURITY.md §"Intentional compromises".
func runArgs(ref Ref, ip, gateway string) ([]string, error) {
	dataDir := DataDir(ref.Engine, ref.Version)
	img := image(ref.Engine, ref.Version)

	args := append([]string{}, podman.OptMountRO...)
	args = append(args,
		"-d", "--name", ref.Container,
		"--network", "mpd-internal:ip="+ip,
		"-v", "mpd-data-volume:/srv",
		"--label", "mpd.managed=true",
		"--label", "mpd.name="+ref.ID,
		"--label", "mpd.ip="+ip,
		"--label", "mpd.type=db",
		"--label", "mpd.db.engine="+ref.Engine,
		"--label", "mpd.db.version="+ref.Version,
		"--label", "com.docker.compose.project=mpd-db",
	)
	args = append(args, podman.DNSOpts(gateway)...)

	switch ref.Engine {
	case "postgres":
		args = append(args,
			"-e", "POSTGRES_USER=postgres",
			"-e", "POSTGRES_PASSWORD=postgres",
			"-e", "PGDATA="+dataDir,
			img,
			// synchronous_commit=off only risks losing the last fraction
			// of a second of commits on a crash — bounded, no corruption.
			// full_page_writes=off is deliberately NOT set: it turns an
			// unclean shutdown into a torn page postgres cannot repair,
			// and unclean shutdowns are routine here (OOM, VM reset).
			"postgres", "-c", "synchronous_commit=off",
		)
	case "mariadb":
		args = append(args,
			"-e", "MARIADB_ROOT_PASSWORD=root",
			img,
			"--character-set-server=utf8mb4", "--collation-server=utf8mb4_bin",
			"--datadir="+dataDir,
			"--innodb_file_per_table=On", "--wait-timeout=28800", "--skip-log-bin",
		)
	case "mysql":
		args = append(args,
			"-e", "MYSQL_ROOT_PASSWORD=root",
			img,
			"--character-set-server=utf8mb4", "--collation-server=utf8mb4_bin",
			"--datadir="+dataDir,
			"--skip-log-bin",
		)
	default:
		return nil, unknownEngine(ref.Engine)
	}
	return args, nil
}

// Ensure creates the container if absent, starts it if stopped, and
// waits for it to accept connections. Idempotent: a running and healthy
// container is left alone and nothing is printed.
func Ensure(ctx context.Context, ref Ref, p *podman.Client, n net.Net, uid string,
	out interface{ Write([]byte) (int, error) }) error {

	if err := srv.MkdirAll(srv.DBs); err != nil {
		return err
	}

	var created, started bool
	switch {
	case !p.Exists(ctx, ref.Container):
		img := image(ref.Engine, ref.Version)
		fmt.Fprintf(out, "Pulling %s...\n", img)
		if code, err := p.Pull(ctx, img); err != nil || code != 0 {
			return fmt.Errorf("Failed to pull image '%s'.", img)
		}
		ip, err := AllocateIP(ctx, p, n)
		if err != nil {
			return err
		}
		fmt.Fprintf(out, "%s: creating DB container at %s...\n", ref.Container, ip)
		args, err := runArgs(ref, ip, n.Gateway())
		if err != nil {
			return err
		}
		if code, err := p.Run(ctx, args); err != nil || code != 0 {
			return fmt.Errorf("Failed to create DB container '%s'.", ref.Container)
		}
		created = true

	case !p.Running(ctx, ref.Container):
		fmt.Fprintf(out, "%s: starting...\n", ref.Container)
		if code, err := p.Start(ctx, ref.Container); err != nil || code != 0 {
			return fmt.Errorf("Failed to start DB container '%s'.", ref.Container)
		}
		started = true
	}

	// Probed unconditionally, not just when mpd touched the container:
	// "running" is a podman fact, not a database one, and a container
	// started by the boot units or by an earlier command may still be
	// initialising. Callers go straight on to issue SQL.
	if err := WaitFor(ctx, ref, p, out); err != nil {
		return err
	}

	switch {
	case created:
		fmt.Fprintf(out, "\033[1;32m✓ %s is ready.\033[0m\n", ref.Container)
	case started:
		fmt.Fprintf(out, "\033[1;32m✓ %s is running.\033[0m\n", ref.Container)
	}
	return nil
}

// Drop removes a project's database and user from a running engine.
//
// Per-project credentials are all the project name (user = password =
// database), a documented dev-only choice — see docs/SECURITY.md.
func Drop(ctx context.Context, out io.Writer, engine, container, dbName string, p *podman.Client) error {
	fmt.Fprintf(out, "Dropping database and user '%s' from %s...\n", dbName, container)

	switch engine {
	case "postgres":
		// Database first: a role still owning objects cannot be dropped.
		codeDB := p.ExecQuietly(ctx, container, "psql", "-U", "postgres", "-c",
			fmt.Sprintf(`DROP DATABASE IF EXISTS "%s";`, dbName))
		p.ExecQuietly(ctx, container, "psql", "-U", "postgres", "-c",
			fmt.Sprintf(`DROP ROLE IF EXISTS "%s";`, dbName))
		if codeDB != 0 {
			return fmt.Errorf("Failed to drop database '%s'.", dbName)
		}
	case "mariadb", "mysql":
		sql := fmt.Sprintf("DROP DATABASE IF EXISTS `%s`;\nDROP USER IF EXISTS '%s'@'%%';", dbName, dbName)
		client := "mariadb"
		if engine == "mysql" {
			client = "mysql"
		}
		if code := p.ExecQuietly(ctx, container, client, "-u", "root", "-proot", "-e", sql); code != 0 {
			return fmt.Errorf("Failed to drop database '%s'.", dbName)
		}
	default:
		return unknownEngine(engine)
	}
	return nil
}

// CreateFor creates a per-project user and database in a running engine.
//
// Idempotent: re-running on an existing project is a no-op, because
// `mpd configure` runs it every time and must not fail on the second
// call. User, password and database name are all the project name — a
// documented dev-only choice (docs/SECURITY.md).
func CreateFor(ctx context.Context, out io.Writer, engine, container, dbName string, p *podman.Client) error {
	fmt.Fprintf(out, "Creating user and database '%s' in %s...\n", dbName, container)

	switch engine {
	case "postgres":
		// Role first, idempotently: CREATE ROLE has no IF NOT EXISTS, so
		// the check has to happen inside a DO block.
		role := fmt.Sprintf(
			`DO $$ BEGIN IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = '%s') `+
				`THEN CREATE ROLE "%s" LOGIN PASSWORD '%s'; `+
				`ELSE ALTER ROLE "%s" WITH LOGIN PASSWORD '%s'; END IF; END $$;`,
			dbName, dbName, dbName, dbName, dbName)
		if code := p.ExecQuietly(ctx, container, "psql", "-U", "postgres", "-c", role); code != 0 {
			return fmt.Errorf("Failed to ensure PostgreSQL role '%s'.", dbName)
		}

		// CREATE DATABASE cannot run inside a DO block or transaction, so
		// probe first and only create when missing.
		res, err := p.ExecCapture(ctx, container, "psql", "-U", "postgres", "-tAc",
			fmt.Sprintf("SELECT 1 FROM pg_database WHERE datname='%s';", dbName))
		if err != nil || res.Code != 0 {
			return fmt.Errorf("Failed to check PostgreSQL database '%s'.", dbName)
		}
		if strings.TrimSpace(res.Stdout) == "1" {
			return nil
		}
		create := fmt.Sprintf(`CREATE DATABASE "%s" OWNER "%s";`, dbName, dbName)
		if code := p.ExecQuietly(ctx, container, "psql", "-U", "postgres", "-c", create); code != 0 {
			return fmt.Errorf("Failed to create database '%s'.", dbName)
		}

	case "mariadb", "mysql":
		sql := fmt.Sprintf(
			"CREATE DATABASE IF NOT EXISTS `%s` CHARACTER SET utf8mb4 COLLATE utf8mb4_bin;\n"+
				"CREATE USER IF NOT EXISTS '%s'@'%%' IDENTIFIED BY '%s';\n"+
				"GRANT ALL PRIVILEGES ON `%s`.* TO '%s'@'%%';\nFLUSH PRIVILEGES;",
			dbName, dbName, dbName, dbName, dbName)
		// MariaDB 12.x dropped the `mysql` CLI symlink — use the engine's
		// own binary rather than assuming they are interchangeable.
		cli := "mysql"
		if engine == "mariadb" {
			cli = "mariadb"
		}
		if code := p.ExecQuietly(ctx, container, cli, "-u", "root", "-proot", "-e", sql); code != 0 {
			return fmt.Errorf("Failed to create database '%s'.", dbName)
		}

	default:
		return unknownEngine(engine)
	}
	return nil
}
