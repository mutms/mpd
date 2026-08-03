# mpd is a single Go binary, built from go/ into bin/mpd.
#
# The binary must land at /opt/mpd/bin/mpd: the systemd user unit, the
# bootstrap scripts and the shipped PATH entry all name that absolute
# path. `build` and `install` are the same target — a Go build writes the
# finished binary directly, so there is nothing left to install.
GO_DIR := $(CURDIR)/go

# Build with the Go that Debian Trixie ships (golang-go, currently
# 1.24.x) and nothing else.
#
# Go's default GOTOOLCHAIN=auto silently downloads a whole toolchain —
# 210 MB — when go.mod, or any dependency's go.mod, names a newer
# version than the installed one. That happens per VM, at build time,
# over the network, with no warning. `local` turns it into an immediate,
# legible build failure instead.
#
# If you hit that failure: lower the `go` directive in go/go.mod, or
# pick a dependency version whose own go.mod fits — do not raise the
# floor above what Trixie packages.
export GOTOOLCHAIN = local

.PHONY: build install clean test vet fmt fmt-check lint-shell fmt-shell tidy

build install:
	@mkdir -p bin
	cd $(GO_DIR) && go build -o $(CURDIR)/bin/mpd ./cmd/mpd
	@echo "Native binary: bin/mpd"

test:
	cd $(GO_DIR) && go test ./...

vet:
	cd $(GO_DIR) && go vet ./...

# Apply canonical Go formatting.
fmt:
	cd $(GO_DIR) && gofmt -w .

# Fail if anything is not gofmt-clean (for CI / pre-commit).
fmt-check:
	@out=$$(cd $(GO_DIR) && gofmt -l .); \
	if [ -n "$$out" ]; then echo "not gofmt-clean:"; echo "$$out"; exit 1; fi
	@echo "gofmt clean"

# Every shell script mpd ships, identified by content rather than by
# extension: the in-runtime tools are deliberately extensionless
# (composer-install, phpunit, the php wrapper).
SHELL_FILES = $$(find bootstrap bin assets setup -type f -exec file --mime-type {} + | grep x-shellscript | cut -d: -f1)

# Lint the shell half of mpd. Go has vet + gofmt; this is the equivalent
# for the ~75 scripts under assets/, bootstrap/, bin/ and setup/.
#
# SC2034 (unused variable) is excluded, not silenced file by file: mpd's
# env helpers exist to SET variables for whoever sources them —
# tools/php assigns PROJECT_NAME purely so the source-mpd-env.sh it then
# sources can read it. shellcheck cannot see across that boundary, so
# every hit is a false positive.
lint-shell:
	@shellcheck -S warning -e SC2034 $(SHELL_FILES) && echo "shellcheck clean"

# Apply shell formatting. Not wired into a check target: shfmt disagrees
# with about half of these files today, and reformatting them wholesale
# would bury real changes in whitespace. Run it on files you are already
# touching.
fmt-shell:
	@shfmt -w -i 4 $(SHELL_FILES) && echo "shfmt applied"

tidy:
	cd $(GO_DIR) && go mod tidy

clean:
	rm -f bin/mpd
	cd $(GO_DIR) && go clean -cache -testcache
