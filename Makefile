# Swift targets build the current `mpd`; go-* targets build `gompd`, the
# in-progress Go port. Both write into bin/. See docs/proposals/go-port.md.
GO_DIR := $(CURDIR)/go

.PHONY: build install clean go-build go-install go-test go-vet go-fmt go-fmt-check go-difftest go-tidy go-clean

build:
	swift build

install:
	swift build -c release --static-swift-stdlib
	@mkdir -p bin
	@install "$(CURDIR)/.build/release/mpd" "bin/mpd"
	@echo "Native binary: bin/mpd"

clean:
	swift package clean

# ── Go port ──────────────────────────────────────────────────────────────
# Built as `gompd` so it can be installed alongside the Swift binary. At
# the end of the port this becomes plain `mpd` and the Swift targets go.

go-build:
	@mkdir -p bin
	cd $(GO_DIR) && go build -o $(CURDIR)/bin/gompd ./cmd/mpd
	@echo "Native binary: bin/gompd"

go-install: go-build

go-test:
	cd $(GO_DIR) && go test ./...

go-vet:
	cd $(GO_DIR) && go vet ./...

# Apply canonical Go formatting.
go-fmt:
	cd $(GO_DIR) && gofmt -w .

# Fail if anything is not gofmt-clean (for CI / pre-commit).
go-fmt-check:
	@out=$$(cd $(GO_DIR) && gofmt -l .); \
	if [ -n "$$out" ]; then echo "not gofmt-clean:"; echo "$$out"; exit 1; fi
	@echo "gofmt clean"

# Compare Go output against Swift output for every verb both implement.
# Requires both binaries: make install go-build
go-difftest:
	@bash $(GO_DIR)/difftest.sh

go-tidy:
	cd $(GO_DIR) && go mod tidy

go-clean:
	rm -f bin/gompd
	cd $(GO_DIR) && go clean -cache -testcache
