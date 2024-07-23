package mere

import (
	"errors"
	"fmt"
	"net/http"
	"net/url"
	"os"
	"time"

	"github.com/fcjr/aia-transport-go"
)

var (
	errNoProtoScheme       = errors.New("missing protocol scheme")
	errBadProtoScheme      = errors.New("unsupported protocol scheme")
	ErrStoreBadGroup       = errors.New("incorrect group")
	ErrStoreBadPermissions = errors.New("incorrect permissions")
	ErrStoreIsFile         = errors.New("store is a file")
)

const (
	defaultStorePath = "/mere"
	fileProto        = "file"
	httpProto        = "http"
	httpsProto       = "https"
	dirPerms         = 0o775
)

type Mere struct {
	log        Logger
	httpclient doer
	store      string
}

func validateURL(u string) (*url.URL, error) {
	parsedURL, err := url.Parse(u)
	if err != nil {
		return parsedURL, fmt.Errorf("%w", err)
	}
	switch parsedURL.Scheme {
	case fileProto, httpProto, httpsProto:
		return parsedURL, nil
	case "":
		return parsedURL, fmt.Errorf("%w", errNoProtoScheme)
	default:
		return parsedURL, fmt.Errorf("%w: %s", errBadProtoScheme, parsedURL.Scheme)
	}
}

func NewMere(log Logger, store string) (Mere, error) {
	if store == "" {
		store = defaultStorePath
	}
	mere := Mere{log: log, store: store}
	transport, _ := aia.NewTransport()
	mere.httpclient = &http.Client{
		Timeout:   time.Second * httpTimeout,
		Transport: transport,
	}
	return mere, mere.validate()
}

func (m *Mere) validate() error {
	info, err := os.Stat(m.store)
	if err != nil {
		return fmt.Errorf("failure during stat: %w", err)
	}
	if !info.IsDir() {
		return fmt.Errorf("%w: %s", ErrStoreIsFile, m.store)
	}
	perms := info.Mode().Perm()
	if perms != dirPerms {
		return fmt.Errorf("%w: %s 0%o", ErrStoreBadPermissions, m.store, perms)
	}
	return nil
}
