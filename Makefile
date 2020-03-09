BINARIES := $(patsubst cmd/%,bin/%,$(wildcard cmd/*))
GOLANGCI-LINT-VRS := "1.23.8"

.PHONY: all clean test lint

all: $(BINARIES)
	@echo "built all applications"

lint:
	@[ "$$(golangci-lint --version | awk '{print $$4}')" = "${GOLANGCI-LINT-VRS}" ] || \
	    curl -L -q https://install.goreleaser.com/github.com/golangci/golangci-lint.sh \
		| sh -s -- -b $$(go env GOPATH)/bin v${GOLANGCI-LINT-VRS}
	@golangci-lint run --deadline 30m --enable-all

test: lint
	@go test -v -coverprofile coverage.out ./...
	@go tool cover -func=coverage.out
	@go tool cover -html=coverage.out -o coverage.html

bin/%:
	@CGO_ENABLED=0 go build -a -ldflags "-w -s"  -i -v -o bin/$* cmd/$*/main.go

release:
	@goreleaser release --rm-dist

clean:
	@git clean -xdf
