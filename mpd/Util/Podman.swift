// mpd — Mpd.Podman namespace
//
// **Mandatory architecture rule** — `Mpd.Podman` is the *single* shared
// gateway for every container/runtime operation in the codebase. Direct
// host-OS command execution is allowed only inside `mpd/VM/Exec.swift`.
// Other layers (`CLI`, `Action`, `Runtime`, `Service`, `Hooks`) MUST go
// through Mpd.Podman.
// Full rule + review checklist: `docs/ARCHITECTURE.md` §3 (Mandatory
// Constraint: Host Command Boundary).
//
// External callers (Runtime / DB / Project / Service / Core) call the
// public methods below. Internal helpers (`podmanShell`, `podmanCapture`)
// stay private — they wrap `Mpd.VM.exec/capture` and
// add the `useSudo: true` toggle for rootful Podman on Linux.
//
// Adding a new podman invocation? Add a public method here, not a one-off
// shell call somewhere else.

import Foundation

import Glibc

// MARK: - Container query types (used by Podman, Runtime, Commands, and DB)

struct PsItem: Decodable {
    let Names: [String]
    let Labels: [String: String]?
    let State: String
}

extension Mpd.Podman {
    @discardableResult
    private static func podmanShell(_ args: [String], input: Data? = nil) -> Int32 {
        Mpd.VM.exec(["podman"] + args, input: input, useSudo: true)
    }

    private static func podmanCapture(_ args: [String], suppressStderr: Bool = false) -> (Int32, String) {
        Mpd.VM.capture(["podman"] + args, suppressStderr: suppressStderr, useSudo: true)
    }

    // MARK: - Queries

    /// Returns true if the container exists (any state).
    static func exists(_ name: String) -> Bool {
        podmanCapture([ "container", "exists", name], suppressStderr: true).0 == 0
    }

    /// Returns true if the container is currently running.
    static func running(_ name: String) -> Bool {
        podmanCapture([ "inspect", name, "--format", "{{.State.Running}}"],
                suppressStderr: true).1 == "true"
    }

    /// Read a single label from a container. Returns empty string if missing.
    static func label(_ container: String, _ key: String) -> String {
        podmanCapture([ "inspect", container,
                 "--format", "{{index .Config.Labels \"\(key)\"}}"],
                suppressStderr: true).1
    }

    /// Remove and recreate a container if any tracked labels don't match.
    /// `labels` maps label name -> expected value; empty values are skipped.
    /// Returns true if the container was removed (caller should recreate).
    @discardableResult
    static func removeIfOutdated(_ name: String, labels: [String: String]) -> Bool {
        guard exists(name) else { return false }
        let allOK = labels.allSatisfy { key, expected in
            expected.isEmpty || label(name, key) == expected
        }
        if allOK { return false }
        ok("Upgrading \(name)")
        if running(name) { stopQuietly(name) }
        removeQuietly(name)
        return true
    }

    /// Raw JSON inspect output parsed as array of dictionaries.
    static func inspect(_ name: String) -> [[String: Any]]? {
        let (code, out) = podmanCapture([ "inspect", name, "--format", "json"])
        guard code == 0,
              let data = out.data(using: .utf8),
              let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else { return nil }
        return arr
    }

    /// List containers matching the given label filter, decoded as [PsItem].
    static func ps(filter: String = "label=mpd.managed=true") -> [PsItem] {
        let (code, out) = podmanCapture([ "ps", "-a",
                                   "--filter", filter,
                                   "--format", "json"])
        guard code == 0, !out.isEmpty, out != "null",
              let data = out.data(using: .utf8),
              let items = try? JSONDecoder().decode([PsItem].self, from: data)
        else { return [] }
        return items
    }

    // MARK: - Container lifecycle

    /// `podman run` — args are everything after `podman run`.
    @discardableResult
    static func run(_ args: [String]) -> Int32 {
        podmanShell([ "run"] + args)
    }

    /// `podman run` with all output suppressed (no container ID hash).
    @discardableResult
    static func runQuietly(_ args: [String]) -> Int32 {
        let result = podmanCapture([ "run"] + args, suppressStderr: true)
        return result.0
    }

    /// `podman run` and capture stdout output.
    static func runOutput(_ args: [String], suppressStderr: Bool = false) -> (Int32, String) {
        podmanCapture([ "run"] + args, suppressStderr: suppressStderr)
    }

    /// `podman run` with piped stdin payload.
    @discardableResult
    static func runWithInput(_ args: [String], input: Data) -> Int32 {
        podmanShell([ "run"] + args, input: input)
    }

    /// Start a stopped container.
    @discardableResult
    static func start(_ name: String) -> Int32 {
        podmanShell([ "start", name])
    }

    /// Start a stopped container silently.
    @discardableResult
    static func startQuietly(_ name: String) -> Int32 {
        if debugMode { return podmanShell([ "start", name]) }
        return podmanCapture([ "start", name], suppressStderr: true).0
    }

    /// Stop a running container.
    @discardableResult
    static func stop(_ name: String) -> Int32 {
        podmanShell([ "stop", name])
    }

    /// Stop a running container silently.
    @discardableResult
    static func stopQuietly(_ name: String) -> Int32 {
        if debugMode { return podmanShell([ "stop", name]) }
        return podmanCapture([ "stop", name], suppressStderr: true).0
    }

    /// Remove a container (must be stopped first).
    @discardableResult
    static func remove(_ name: String) -> Int32 {
        podmanShell([ "rm", name])
    }

    /// Remove a container silently.
    @discardableResult
    static func removeQuietly(_ name: String) -> Int32 {
        if debugMode { return podmanShell([ "rm", name]) }
        return podmanCapture([ "rm", name], suppressStderr: true).0
    }

    /// Forcefully remove a container (running or stopped) — SIGKILLs if running.
    /// For teardown paths where graceful shutdown is not needed.
    @discardableResult
    static func removeForcefully(_ name: String) -> Int32 {
        podmanCapture([ "rm", "-f", name], suppressStderr: true).0
    }

    /// Non-interactive exec (inherits stdout).
    @discardableResult
    static func exec(_ container: String, _ args: [String]) -> Int32 {
        podmanShell([ "exec", container] + args)
    }

    /// Non-interactive exec with extra options before container (for example: --user root).
    @discardableResult
    static func exec(_ container: String, options: [String], _ args: [String]) -> Int32 {
        podmanShell([ "exec"] + options + [container] + args)
    }

    /// Non-interactive exec with all output suppressed.
    @discardableResult
    static func execQuietly(_ container: String, _ args: [String]) -> Int32 {
        if debugMode { return podmanShell([ "exec", container] + args) }
        let result = podmanCapture([ "exec", container] + args, suppressStderr: true)
        return result.0
    }

    /// Interactive exec — passes through stdin/stdout/stderr.
    @discardableResult
    static func execInteractive(_ container: String, _ args: [String]) -> Int32 {
        podmanShell([ "exec", "-it", container] + args)
    }

    /// Interactive exec with extra options before container (for example: --user extuser).
    @discardableResult
    static func execInteractive(_ container: String, options: [String], _ args: [String]) -> Int32 {
        podmanShell([ "exec"] + options + ["-it", container] + args)
    }

    /// Exec that captures stdout output. Returns (exitCode, trimmedOutput).
    static func execOutput(_ container: String, _ args: [String],
                           suppressStderr: Bool = true) -> (Int32, String) {
        podmanCapture([ "exec", container] + args, suppressStderr: suppressStderr)
    }

    /// Exec with options and captured stdout.
    static func execOutput(_ container: String, options: [String], _ args: [String],
                           suppressStderr: Bool = true) -> (Int32, String) {
        podmanCapture([ "exec"] + options + [container] + args, suppressStderr: suppressStderr)
    }

    /// `podman cp src dst` (either side may be `container:/path` or a host path).
    @discardableResult
    static func cp(from src: String, to dst: String) -> Int32 {
        podmanShell([ "cp", src, dst])
    }

    /// Stream container logs to stdout.
    @discardableResult
    static func logs(_ name: String) -> Int32 {
        podmanShell([ "logs", "-f", name])
    }

    /// Send a signal to a container.
    @discardableResult
    static func kill(_ name: String, signal: String = "HUP") -> Int32 {
        podmanShell([ "kill", "--signal", signal, name])
    }

    /// Restart a container (stop + start).
    @discardableResult
    static func restart(_ name: String) -> Int32 {
        podmanShell([ "restart", name])
    }

    // MARK: - Pod operations

    /// Returns true if a Podman pod (not just a container) exists.
    static func podExists(_ name: String) -> Bool {
        podmanCapture([ "pod", "exists", name], suppressStderr: true).0 == 0
    }

    /// `podman pod create` — args are everything after `podman pod create`.
    @discardableResult
    static func podCreate(_ args: [String]) -> Int32 {
        podmanShell([ "pod", "create"] + args)
    }

    /// Start a pod and all its containers.
    @discardableResult
    static func podStart(_ name: String) -> Int32 {
        podmanShell([ "pod", "start", name])
    }

    /// Start a pod silently.
    @discardableResult
    static func podStartQuietly(_ name: String) -> Int32 {
        if debugMode { return podmanShell([ "pod", "start", name]) }
        return podmanCapture([ "pod", "start", name], suppressStderr: true).0
    }

    /// Stop a pod and all its containers.
    @discardableResult
    static func podStop(_ name: String) -> Int32 {
        podmanShell([ "pod", "stop", name])
    }

    /// Remove a pod and all its containers (must be stopped first).
    @discardableResult
    static func podRemove(_ name: String) -> Int32 {
        podmanShell([ "pod", "rm", name])
    }

    /// Forcefully remove a pod and all its containers (running or stopped).
    /// For teardown paths where graceful shutdown is not needed.
    @discardableResult
    static func podRemoveForcefully(_ name: String) -> Int32 {
        podmanCapture([ "pod", "rm", "-f", name], suppressStderr: true).0
    }

    // MARK: - Image operations

    /// Returns true if a local image with the given name exists.
    static func imageExists(_ name: String) -> Bool {
        podmanCapture([ "image", "exists", name], suppressStderr: true).0 == 0
    }

    /// Build an image from a Containerfile. Uses `--network=host` so the
    /// build container shares the host's network namespace — needed because
    /// our setup configures `/etc/resolv.conf` as a symlink to
    /// systemd-resolved's stub (127.0.0.53), which is host-loopback-only and
    /// not reachable from a container netns. With `--network=host`, the
    /// FROM-image pull and any in-build `apt-get update` go straight through
    /// the host's working resolver.
    @discardableResult
    static func buildImage(tag: String, contextDir: String) -> Int32 {
        podmanShell([ "build", "--network=host", "-t", tag, contextDir])
    }

    /// Pull an image.
    @discardableResult
    static func pull(_ image: String, quiet: Bool = false) -> Int32 {
        let args = quiet ? ["pull", "-q", image] : ["pull", image]
        if quiet {
            return podmanCapture(args, suppressStderr: true).0
        }
        return podmanShell(args)
    }

    // MARK: - Network operations

    /// Returns true if a Podman network exists.
    static func networkExists(_ name: String) -> Bool {
        podmanCapture([ "network", "exists", name], suppressStderr: true).0 == 0
    }

    @discardableResult
    static func networkCreate(_ name: String, subnet: String? = nil,
                              dnsServers: [String] = []) -> Int32 {
        var args = ["network", "create"]
        if let s = subnet { args += ["--subnet", s] }
        for ip in dnsServers { args += ["--dns", ip] }
        args.append(name)
        return podmanShell(args)
    }

    @discardableResult
    static func networkRemove(_ name: String) -> Int32 {
        podmanShell([ "network", "rm", name])
    }

    /// Read the container's IP address on the given Podman network.
    static func containerIP(_ name: String, network: String = "mpd-internal") -> String {
        // Use index notation — dot notation breaks on hyphenated network names.
        podmanCapture([ "inspect", name, "--format",
                 "{{(index .NetworkSettings.Networks \"\(network)\").IPAddress}}"],
                suppressStderr: true).1
    }

    // MARK: - Volume operations
    //
    // Routed through the always-on `mpd-service-fileaccess` container, which
    // has `mpd-data-volume:/srv` mounted. `podman exec` is ~5-10x faster than
    // `podman run --rm` per call — meaningful across the many small volume ops
    // project create/configure does.
    //
    // All execs run as `$EXTUID:$EXTUID` so files written here come out
    // matching the runtime user (no chown step needed afterward). The
    // historical `volume` / `readOnly` / `name` params are accepted for source
    // compatibility but ignored — the long-running container has a fixed
    // mount, fixed name, and is always read-write.

    private static func volumeToolUserOptions() -> [String] {
        let id = Mpd.VM.detectUserAndUID()
        guard !id.uid.isEmpty else { return [] }
        return ["--user", "\(id.uid):\(id.uid)"]
    }

    @discardableResult
    static func volumeToolRun(
        volume: String = Mpd.dataVolume,
        readOnly: Bool = false,
        interactive: Bool = false,
        name: String? = nil,
        command: [String]
    ) -> Int32 {
        _ = volume; _ = readOnly; _ = name
        let target = Mpd.Service.FileAccess.containerName
        let opts = volumeToolUserOptions()
        if interactive {
            return execInteractive(target, options: opts, command)
        }
        return exec(target, options: opts, command)
    }

    static func volumeToolOutput(
        volume: String = Mpd.dataVolume,
        readOnly: Bool = false,
        name: String? = nil,
        command: [String],
        suppressStderr: Bool = false
    ) -> (Int32, String) {
        _ = volume; _ = readOnly; _ = name
        let target = Mpd.Service.FileAccess.containerName
        let opts = volumeToolUserOptions()
        return execOutput(target, options: opts, command, suppressStderr: suppressStderr)
    }

    @discardableResult
    static func volumeToolRunWithInput(
        volume: String = Mpd.dataVolume,
        readOnly: Bool = false,
        command: [String],
        input: Data
    ) -> Int32 {
        _ = volume; _ = readOnly
        let target = Mpd.Service.FileAccess.containerName
        let opts = volumeToolUserOptions()
        return podmanShell(["exec", "-i"] + opts + [target] + command, input: input)
    }

    /// Returns true if a named Podman volume exists.
    static func volumeExists(_ name: String) -> Bool {
        podmanCapture([ "volume", "exists", name], suppressStderr: true).0 == 0
    }

    @discardableResult
    static func volumeCreate(_ name: String) -> Int32 {
        podmanShell([ "volume", "create", name])
    }

    /// Remove a named Podman volume, ignoring "no such volume". `-f` also
    /// detaches it from any stopped container still referencing it.
    @discardableResult
    static func volumeRemove(_ name: String) -> Int32 {
        podmanShell([ "volume", "rm", "-f", name])
    }

}
