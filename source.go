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

	"github.com/codeclysm/extract/v3"
	"github.com/zeebo/blake3"
)

const (
	errorBoundary = 400
	fileProto     = "file"
	httpProto     = "http"
)

var (
	errfetch   = errors.New("download error")
	errNotADir = errors.New("not a directory")
	errHash    = errors.New("b3sum mismatch")
	errSource  = errors.New("invalid source definition")
	errProto   = errors.New("unsupported or missing protocol scheme")
)

// Source defines the properties needed to retrieve and validate a source file.
type Source struct {
	URL       string `json:"url"`
	B3Sum     string `json:"b3sum" jsonschema:"minLength=64,maxLength=64"`
	LocalName string `json:"localName,omitempty"`
	protocol  string
	savePath  string
	srcPath   string
	output    io.Writer
}

type getter interface {
	Get(string) (*http.Response, error)
}

type copier interface {
	Copy(io.Writer, io.Reader) (int64, error)
}

type copywrapper struct{}

func (c copywrapper) Copy(dst io.Writer, src io.Reader) (int64, error) {
	return io.Copy(dst, src)
}

func (source *Source) fetchHTTP(g getter) error {
	fmt.Fprintf(source.output, "Downloading %s", source.URL)
	resp, err := g.Get(source.URL)
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

	fmt.Fprintf(source.output, "Saving %s", source.savePath)
	_, err = io.Copy(f, resp.Body)
	if err != nil {
		return fmt.Errorf("%w", err)
	}

	return nil
}

func (source *Source) fetchFile(c copier) error {
	src, err := os.Open(source.srcPath)
	if err != nil {
		return fmt.Errorf("%w", err)
	}
	defer src.Close()

	f, err := os.Create(source.savePath)
	if err != nil {
		return fmt.Errorf("%w", err)
	}
	defer f.Close()

	_, err = c.Copy(f, src)
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
	fmt.Fprintf(source.output, "Validating %s", filename)
	sum, err := computeB3SumFromFile(filename)
	if err != nil {
		return err
	}
	if sum != b3sum {
		return fmt.Errorf("%w: expected: %s actual: %s", errHash, b3sum, sum)
	}
	return nil
}

func (source *Source) validateSource() error {
	parsedURL, err := url.Parse(source.URL)
	if err != nil {
		return fmt.Errorf("%w", err)
	}

	switch parsedURL.Scheme {
	case fileProto:
		source.srcPath = parsedURL.Host + parsedURL.Path
		source.protocol = fileProto
	case httpProto, "https":
		source.protocol = httpProto
	case "":
		return fmt.Errorf("%w: missing protocol scheme", errSource)
	default:
		return fmt.Errorf("%w: unsupported protocol scheme: %s", errSource, parsedURL.Scheme)
	}

	if source.LocalName == "" {
		source.LocalName = parsedURL.Path
	}

	savePath, _ := filepath.Abs("/" + path.Base(source.LocalName))
	if savePath == "/" {
		return fmt.Errorf("%w: no path element detected", errSource)
	}

	return nil
}

func (source *Source) fetchSource(spec *Spec) error {
	if err := ensureDir(os.MkdirAll, spec.sourceCache); err != nil {
		return err
	}

	source.savePath = strings.Join([]string{spec.sourceCache, path.Base(source.LocalName)}, "/")

	finfo, _ := os.Stat(source.savePath)
	if finfo != nil {
		return source.checkB3SumFromFile(source.savePath, source.B3Sum)
	}

	switch source.protocol {
	case fileProto:
		if err := source.fetchFile(copywrapper{}); err != nil {
			return err
		}
	case httpProto:
		if err := source.fetchHTTP(spec.httpclient); err != nil {
			return err
		}
	default:
		return fmt.Errorf("%w: %s", errProto, source.protocol)
	}

	if err := source.checkB3SumFromFile(source.savePath, source.B3Sum); err != nil {
		return err
	}

	return nil
}

func (s *Spec) fetchSources() []error {
	errors := make([]error, 0, len(s.Sources))
	for i := range s.Sources {
		if err := s.Sources[i].fetchSource(s); err != nil {
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
	fmt.Fprintf(source.output, "Extracting %s", source.savePath)
	err = extract.Archive(context.Background(), f, dir, nil)
	if err != nil {
		return fmt.Errorf("%w", err)
	}
	return nil
}
