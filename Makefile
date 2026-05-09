.PHONY: build release install clean check check-hostexec-boundary check-mpdenv-source-boundary check-privilege-boundary

build:
	swift build

release: install
	@mkdir -p release
	@for platform in macos-utm ubuntu-kvm windows-hyperv; do \
		out="release/$$platform.zip"; \
		rm -f "$$out"; \
		(cd setup && zip -qr "../$$out" "$$platform" \
			--exclude "*/.DS_Store" \
			--exclude "*/temp/*" \
			--exclude "*/__MACOSX/*"); \
		echo "  $$out"; \
	done
	@echo "Platform zips in release/ (sandbox is distributed as the raw"
	@echo "URL of setup/sandbox/take-over-sandbox-vm.sh; no zip needed)."

install:
	@os=$$(uname -s); \
	case "$$os" in \
		Darwin) swift build -c release ;; \
		Linux)  swift build -c release --static-swift-stdlib ;; \
		*) echo "Unsupported host OS: $$os" >&2; exit 1 ;; \
	esac; \
	mkdir -p bin; \
	install "$(CURDIR)/.build/release/mpd" "bin/mpd"; \
	echo "Native binary: bin/mpd"

clean:
	swift package clean
check-hostexec-boundary:
	@violations=$$(grep -Rsn "Process(" mpd --include='*.swift' | grep -v "mpd/Environment/Desktop/DesktopHostExec.swift" | grep -v "mpd/Environment/Machine/MachineHostExec.swift" || true); \
	if [ -n "$$violations" ]; then \
		echo "HostExec boundary violation: Process() found outside HostExec files:"; \
		echo "$$violations"; \
		exit 1; \
	fi; \
	echo "HostExec boundary check passed."

# Bash-sourcing an mpd*.env file is a code-execution sink — values like
# MPD_FOO=$(rm -rf ~) in a project's mpd.env (cloned from git) would run.
# All env-file loading must go through source-mpd-env.sh, which uses a
# strict KEY=VALUE whitelist parser (no eval, no source).
check-mpdenv-source-boundary:
	@violations=$$(grep -RInE '(\bsource[[:space:]]+|(^|[[:space:]])\.[[:space:]]+)["'\''"]?[^"'\''[:space:]]*mpd[-a-z]*\.env' \
		assets/ mpd-machine/ \
		--include='*.sh' --include='*.bash' 2>/dev/null || true); \
	if [ -n "$$violations" ]; then \
		echo "mpd.env source boundary violation: raw 'source'/'.' of an mpd*.env file detected."; \
		echo "Use 'source /mnt/assets/runtime-base/lib/source-mpd-env.sh' instead."; \
		echo "Its whitelist parser blocks command injection from project mpd.env files."; \
		echo "$$violations"; \
		exit 1; \
	fi; \
	echo "mpd.env source boundary check passed."

# Privilege rule (AGENTS.md §"Mandatory privilege rule"). Scope:
# in-runtime/in-VM/in-service shell code — assets/ in full, plus the
# in-VM scripts of the sandbox platform (siblings like
# setup/macos-utm/create-vm.sh that run on the user's host are out of
# scope). Bans:
#   - `sudo` wrapping a script file (`sudo bash foo.sh`, `sudo foo.sh`).
#     `sudo bash -c '…'` / `sudo sh -c '…'` one-liners are allowed —
#     they're a single privileged command, not a whole script.
#   - identity-switching to a non-root user: `sudo -u <user>`,
#     `runuser`, `su -`, `su <user>`, `su <user> -c …`.
check-privilege-boundary:
	@violations=$$(grep -RInE '(\bsudo[[:space:]]+(bash|sh)[[:space:]]+[^-[:space:]]|\bsudo[[:space:]]+[^-[:space:]][^[:space:]]*\.(sh|bash)\b|\bsudo[[:space:]]+-u\b|\brunuser\b|\bsu[[:space:]]+\S)' \
		assets/ \
		setup/sandbox/take-over-sandbox-vm.sh \
		setup/sandbox/lib/provision.sh \
		--include='*.sh' --include='*.bash' 2>/dev/null || true); \
	if [ -n "$$violations" ]; then \
		echo "Privilege boundary violation: forbidden shape detected."; \
		echo "Rule: AGENTS.md §\"Mandatory privilege rule\"."; \
		echo "Banned: 'sudo bash script.sh', 'sudo -u <user>', 'runuser', 'su <user>', 'su - <user>'."; \
		echo "$$violations"; \
		exit 1; \
	fi; \
	echo "Privilege boundary check passed."

check: check-hostexec-boundary check-mpdenv-source-boundary check-privilege-boundary

