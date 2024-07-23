package mere

import (
	"context"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
)

var errHTTPcode = errors.New("received an HTTP error")

const (
	errorBoundary = 400
	httpTimeout   = 30
)

type copier interface {
	Copy(dst io.Writer, src io.Reader) (int64, error)
}

type copywrapper struct{}

func (c copywrapper) Copy(dst io.Writer, src io.Reader) (int64, error) {
	return io.Copy(dst, src) //nolint:wrapcheck // We want the simplest possible wrap here
}

type doer interface {
	Do(request *http.Request) (*http.Response, error)
}

// fetchFile copies a src file to a destination file, using a provided Copier.
func fetchFile(c copier, src string, dest string) error {
	s, err := os.Open(src)
	if err != nil {
		return fmt.Errorf("%w", err)
	}
	defer s.Close()

	d, err := os.Create(dest)
	if err != nil {
		return fmt.Errorf("%w", err)
	}
	defer d.Close()

	_, err = c.Copy(d, s)
	if err != nil {
		return fmt.Errorf("%w", err)
	}

	return nil
}

// fetchHTTP retrieves an HTTP source and saves the response to a destination file.
func fetchHTTP(d doer, src string, dest string) error {
	var requestBody io.ReadCloser
	req, _ := http.NewRequestWithContext(context.Background(), http.MethodGet, src, requestBody)
	resp, err := d.Do(req)
	if err != nil {
		return fmt.Errorf("%w", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode >= errorBoundary {
		return fmt.Errorf("%w: %d %s", errHTTPcode, resp.StatusCode, http.StatusText(resp.StatusCode))
	}
	f, err := os.Create(dest)
	if err != nil {
		return fmt.Errorf("%w", err)
	}
	defer f.Close()
	_, err = io.Copy(f, resp.Body)
	if err != nil {
		return fmt.Errorf("%w", err)
	}
	return nil
}

// fetch takes a given URL u, fetches it using the method appropriate for the
// protocol scheme and saves it to destFile.
func (m Mere) fetch(u url.URL, destFile string) error {
	destPath, _ := filepath.Abs(destFile)
	if err := ensureDir(os.MkdirAll, filepath.Dir(destPath)); err != nil {
		return err
	}
	switch u.Scheme {
	case fileProto:
		if err := fetchFile(copywrapper{}, u.Path, destPath); err != nil {
			return err
		}
	case httpProto, httpsProto:
		if err := fetchHTTP(m.httpclient, u.String(), destPath); err != nil {
			return err
		}
	default:
		return fmt.Errorf("%w: %s", errBadProtoScheme, u.Scheme)
	}
	return nil
}
