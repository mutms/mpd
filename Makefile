# mpd is a single Go binary, built from go/ into bin/mpd.
#
# The binary must land at /opt/mpd/bin/mpd: the systemd user unit, the
# bootstrap scripts and the shipped PATH entry all name that absolute
# path. `build` and `install` are the same target — a Go build writes the
# finished binary directly, so there is nothing left to install.
GO_DIR := $(CURDIR)/go

# Version stamped into the binary (`mpd version`). mpd is always compiled
# from this checkout, so the value is diagnostic: `git describe` gives the
# nearest tag, or the bare commit hash before any tag exists, with "-dirty"
# appended for uncommitted changes — enough to know exactly which code a
# misbehaving binary was built from.
VERSION := $(shell git -C $(CURDIR) describe --tags --always --dirty 2>/dev/null || echo dev)
LDFLAGS := -X main.version=$(VERSION)

# Go comes from upstream, not Debian: bootstrap/30-mpd-build.sh installs a
# pinned release into /usr/local/go as the seed.
#
# The `go` directive in go/go.mod picks the compiler: the go command
# fetches that toolchain itself when the installed one is older
# (GOTOOLCHAIN=auto, the default). Bump the directive to move to a newer
# Go; the VM's own install (bootstrap/30-mpd-build.sh) is only the seed.

.PHONY: build install clean test vet fmt fmt-check lint-shell fmt-shell tidy

build install:
	@mkdir -p bin
	cd $(GO_DIR) && go build -ldflags "$(LDFLAGS)" -o $(CURDIR)/bin/mpd ./cmd/mpd
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
