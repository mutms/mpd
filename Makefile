# mpd is a single Go binary, built from go/ into bin/mpd.
#
# The binary must land at /opt/mpd/bin/mpd: the systemd user unit, the
# bootstrap scripts and the shipped PATH entry all name that absolute
# path. `build` and `install` are the same target — a Go build writes the
# finished binary directly, so there is nothing left to install.
GO_DIR := $(CURDIR)/go

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
