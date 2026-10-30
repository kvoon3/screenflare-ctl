SWIFTC ?= swiftc
PREFIX ?= $(HOME)/.local
BIN := bin/screenflare-ctl
SRC := Sources/screenflare-ctl/main.swift

.PHONY: all build install uninstall clean check

all: build

build: $(BIN)

$(BIN): $(SRC)
	@mkdir -p bin
	$(SWIFTC) -O -swift-version 5 $(SRC) -o $(BIN)

install: build
	@mkdir -p $(PREFIX)/bin
	@ln -sf "$(CURDIR)/$(BIN)" "$(PREFIX)/bin/screenflare-ctl"
	@echo "installed $(PREFIX)/bin/screenflare-ctl"

uninstall:
	@rm -f "$(PREFIX)/bin/screenflare-ctl"

# Read-only smoke test: needs Screenflare running and Accessibility for this terminal.
check: build
	@./$(BIN) doctor

clean:
	@rm -rf bin
