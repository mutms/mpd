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
# over the network, with no warning: exactly the cost we removed by
# dropping the Swift toolchain. `local` turns it into an immediate,
# legible build failure instead.
#
# If you hit that failure: lower the `go` directive in go/go.mod, or
# pick a dependency version whose own go.mod fits — do not raise the
# floor above what Trixie packages.
export GOTOOLCHAIN = local

.PHONY: build install clean test vet fmt fmt-check tidy

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

tidy:
	cd $(GO_DIR) && go mod tidy

clean:
	rm -f bin/mpd
	cd $(GO_DIR) && go clean -cache -testcache
