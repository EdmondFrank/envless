.PHONY: build test test-watch lint clean

BINARY := bin/envless
PKG    := ./...
VERSION ?= $(shell git describe --tags --always --dirty 2>/dev/null || echo "dev")

build:
	@mkdir -p bin
	go build -trimpath -ldflags "-s -w -X main.version=$(VERSION)" -o $(BINARY) ./cmd/envless

test:
	@go test -count=1 $(PKG)

test-watch:
	@./scripts/test-watch.sh

lint:
	@go vet $(PKG)
	@test -z "$$(gofmt -l . | tee /dev/stderr)"

clean:
	@rm -rf bin dist coverage.out
