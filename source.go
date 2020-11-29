package mere

import (
	"context"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"os"
	"path"
	"path/filepath"
	"strings"
	"time"

	"github.com/codeclysm/extract/v3"
	"github.com/zeebo/blake3"
)

const (
	errorBoundary = 400
	timeout       = 30
)

var (
	errfetch   = errors.New("download error")
	errNotADir = errors.New("not a directory")
	errHash    = errors.New("b3sum mismatch")
	errSource  = errors.New("invalid source definition")
)

// Source defines the properties needed to retrieve and validate a source file.
type Source struct {
	URL        string `json:"url"`
	B3Sum      string `json:"b3sum" jsonschema:"minLength=64,maxLength=64"`
	LocalName  string `json:"localName,omitempty"`
	httpclient getter
	fetch      func() error
	savePath   string
	printHook  func(string)
}

type getter interface {
	Get(string) (*http.Response, error)
}

func (source *Source) fetchHTTP() error {
	source.printHook(fmt.Sprintf("Downloading %s", source.URL))
	resp, err := source.httpclient.Get(source.URL)
	if err != nil {
		return fmt.Errorf("%w", err)
	}
	defer resp.Body.Close()

	if resp.StatusCode >= errorBoundary {
		return fmt.Errorf("%w: %s", errfetch, http.StatusText(resp.StatusCode))
	}

	f, err := os.Create(source.savePath)
	if err != nil {
		return fmt.Errorf("%w", err)
	}
	defer f.Close()

	source.printHook(fmt.Sprintf("Saving %s", source.savePath))
	_, err = io.Copy(f, resp.Body)
	if err != nil {
		return fmt.Errorf("%w", err)
	}

	return nil
}

func computeB3Sum(f io.Reader) (string, error) {
	var buf []byte
	hash := blake3.New()
	if _, err := io.Copy(hash, f); err != nil {
		return "", fmt.Errorf("%w", err)
	}
	sum := hash.Sum(buf)
	return hex.EncodeToString(sum), nil
}

func computeB3SumFromFile(filename string) (string, error) {
	f, err := os.Open(filename)
	if err != nil {
		return "", fmt.Errorf("%w", err)
	}
	defer f.Close()
	return computeB3Sum(f)
}

type mkdirall func(string, os.FileMode) error

func ensureDir(md mkdirall, path string) error {
	finfo, err := os.Stat(path)
	if err != nil {
		if os.IsNotExist(err) {
			if err := md(path, 0o755); err != nil {
				return err
			}
			return nil
		}
		return fmt.Errorf("%w", err)
	}
	if !finfo.IsDir() {
		return fmt.Errorf("%w: %s", errNotADir, path)
	}
	return nil
}

func (source *Source) checkB3SumFromFile(filename string, b3sum string) error {
	source.printHook(fmt.Sprintf("Validating %s", filename))
	sum, err := computeB3SumFromFile(filename)
	if err != nil {
		return err
	}
	if sum != b3sum {
		return fmt.Errorf("%w: expected: %s actual: %s", errHash, b3sum, sum)
	}
	return nil
}

func (source *Source) validateSource(cache string) error {
	parsedURL, err := url.Parse(source.URL)
	if err != nil {
		return fmt.Errorf("%w", err)
	}

	switch parsedURL.Scheme {
	case "http", "https":
		source.fetch = source.fetchHTTP
	case "":
		return fmt.Errorf("%w: missing protocol scheme", errSource)
	default:
		return fmt.Errorf("%w: unsupported protocol scheme: %s", errSource, parsedURL.Scheme)
	}

	if source.LocalName == "" {
		source.LocalName = parsedURL.Path
	}

	savePath, _ := filepath.Abs(strings.Join([]string{cache, path.Base(source.LocalName)}, "/"))

	absSourcePath, _ := filepath.Abs(cache)
	if savePath == absSourcePath {
		return fmt.Errorf("%w: no path element detected", errSource)
	}

	source.savePath = savePath

	return nil
}

func (source *Source) fetchSource(cache string) error {
	if err := ensureDir(os.MkdirAll, cache); err != nil {
		return err
	}

	err := source.validateSource(cache)
	if err != nil {
		return err
	}

	finfo, _ := os.Stat(source.savePath)
	if finfo != nil {
		return source.checkB3SumFromFile(source.savePath, source.B3Sum)
	}

	if err = source.fetch(); err != nil {
		return err
	}

	if err := source.checkB3SumFromFile(source.savePath, source.B3Sum); err != nil {
		return err
	}

	return nil
}

type transportCreator func() (*http.Transport, error)

func fetchSources(sources []Source, cache string, fn transportCreator) []error {
	errors := make([]error, 0, len(sources))
	for i := range sources {
		tr, err := fn()
		if err != nil {
			errors = append(errors, err)
			continue
		}
		sources[i].httpclient = &http.Client{
			Timeout:   time.Second * timeout,
			Transport: tr,
		}
		if err := sources[i].fetchSource(cache); err != nil {
			errors = append(errors, err)
		}
	}
	return errors
}

func (source *Source) extract(dir string) error {
	f, err := os.Open(source.savePath)
	if err != nil {
		return fmt.Errorf("%w", err)
	}
	defer f.Close()
	source.printHook(fmt.Sprintf("Extracting %s", source.savePath))
	err = extract.Archive(context.Background(), f, dir, nil)
	if err != nil {
		return fmt.Errorf("%w", err)
	}
	return nil
}
