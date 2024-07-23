BINARIES := $(patsubst cmd/%,bin/%,$(wildcard cmd/*))
GOLANGCI-LINT-VRS := "1.59.1"

.PHONY: all clean test lint

all: $(BINARIES)
	@echo "built all binaries"

lint:
	@[ "$$($$(go env GOPATH)/bin/golangci-lint --version | awk '{print $$4}')" = "${GOLANGCI-LINT-VRS}" ] || \
	    curl -sSfL https://raw.githubusercontent.com/golangci/golangci-lint/master/install.sh \
		| sh -s -- -b $$(go env GOPATH)/bin v${GOLANGCI-LINT-VRS}
	@$$(go env GOPATH)/bin/golangci-lint run -c .golangci.yaml

test: lint
	@go run gotest.tools/gotestsum@latest -- -race -coverprofile coverage.out ./...
	@go tool cover -func=coverage.out
	@go tool cover -html=coverage.out -o coverage.html

#@go test -v -coverprofile coverage.out ./...

bin/%:
	@CGO_ENABLED=0 go build -a -ldflags "-s -w" -o bin/$* cmd/$*/main.go

clean:
	@git clean -xdf
