.PHONY: build install clean

build:
	swift build

install:
	swift build -c release --static-swift-stdlib
	@mkdir -p bin
	@install "$(CURDIR)/.build/release/mpd" "bin/mpd"
	@echo "Native binary: bin/mpd"

clean:
	swift package clean
