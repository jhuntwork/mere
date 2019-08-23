BINARIES := $(patsubst cmd/%,bin/%,$(wildcard cmd/*))
GOLANGCI-LINT-VRS := 'v1.17.1'

.PHONY: all clean test lint

all: $(BINARIES)
	@echo "built all applications"

staticcheck:
	@command -v staticcheck >/dev/null || go get honnef.co/go/tools/cmd/staticcheck
	@staticcheck ./...

lint: staticcheck
	@command -v golangci-lint >/dev/null || \
	    curl -L -q https://install.goreleaser.com/github.com/golangci/golangci-lint.sh \
		| sh -s -- -b $$(go env GOPATH)/bin ${GOLANGCI-LINT-VERS}
	@golangci-lint run --deadline 30m --enable-all

test:
	@go test -v -coverprofile coverage.out ./...
	@go tool cover -func=coverage.out
	@go tool cover -html=coverage.out -o coverage.html

bin/%:
	@CGO_ENABLED=0 go build -a -ldflags "-w -s"  -i -v -o bin/$* cmd/$*/main.go

release:
	@goreleaser release --rm-dist

clean:
	@git clean -xdf