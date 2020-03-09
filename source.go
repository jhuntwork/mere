package mere

import (
	"encoding/hex"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"os"
	"path"
	"path/filepath"
	"strings"

	rhttp "github.com/hashicorp/go-retryablehttp"
	"github.com/sirupsen/logrus"
	"golang.org/x/crypto/blake2b"
)

const errorBoundary = 400
const hashSize = 32

// Source defines the properties needed to retrieve and validate a source file.
type Source struct {
	URL        string `json:"url"`
	Blake2     string `json:"blake2" jsonschema:"minLength=64,maxLength=64"`
	LocalName  string `json:"localName,omitempty"`
	httpclient getter
	fetch      func() error
	savePath   string
}

type getter interface {
	Get(string) (*http.Response, error)
}

func (s *Source) fetchHTTP() error {
	logrus.WithFields(logrus.Fields{
		"filename": s.savePath,
		"URL":      s.URL,
	}).Debug("downloading")

	resp, err := s.httpclient.Get(s.URL)
	if err != nil {
		return err
	}
	defer resp.Body.Close()

	if resp.StatusCode >= errorBoundary {
		return fmt.Errorf("%s", http.StatusText(resp.StatusCode))
	}

	f, err := os.Create(s.savePath)
	if err != nil {
		return err
	}
	defer f.Close()
	_, err = io.Copy(f, resp.Body)

	return err
}

// ComputeBlake2 returns the Blake2 sum of a given io.Reader as a string.
func ComputeBlake2(f io.Reader) (string, error) {
	var buf []byte

	hash, _ := blake2b.New(hashSize, nil)
	if _, err := io.Copy(hash, f); err != nil {
		return "", err
	}

	sum := hash.Sum(buf)

	return hex.EncodeToString(sum), nil
}

func computeBlake2FromFile(filename string) (string, error) {
	f, err := os.Open(filename)
	if err != nil {
		return "", err
	}
	defer f.Close()

	return ComputeBlake2(f)
}

type mkdirall func(string, os.FileMode) error

func ensureDir(md mkdirall, path string) error {
	finfo, err := os.Stat(path)
	if err != nil {
		if os.IsNotExist(err) {
			logrus.Debugf("Creating source cache directory: %s", path)

			if err := md(path, 0755); err != nil {
				return err
			}

			return nil
		}

		return err
	}

	if !finfo.IsDir() {
		return fmt.Errorf("%s exists but is not a directory", path)
	}

	return nil
}

func checkBlake2SumFromFile(filename string, blake2 string) error {
	logrus.WithFields(logrus.Fields{
		"filename": filename,
		"expected": blake2,
	}).Debug("validating")

	sum, err := computeBlake2FromFile(filename)
	if err != nil {
		return err
	}

	if sum != blake2 {
		logrus.WithFields(logrus.Fields{
			"filename": filename,
			"expected": blake2,
			"actual":   sum,
		}).Error("blake2 sum mismatch")

		return fmt.Errorf("blake2 sum mismatch")
	}

	return nil
}

func (s *Source) validateSource(cache string) error {
	var localName string

	parsedURL, err := url.Parse(s.URL)
	if err != nil {
		return err
	}

	switch parsedURL.Scheme {
	case "http", "https":
		s.fetch = s.fetchHTTP
	case "":
		return fmt.Errorf("missing protocol scheme")
	default:
		return fmt.Errorf("unsupported protocol scheme: %s", parsedURL.Scheme)
	}

	if s.LocalName == "" {
		localName = parsedURL.Path
	} else {
		localName = s.LocalName
	}

	savePath, _ := filepath.Abs(strings.Join([]string{cache, path.Base(localName)}, "/"))

	absSourcePath, _ := filepath.Abs(cache)
	if savePath == absSourcePath {
		return fmt.Errorf("no path element detected")
	}

	s.savePath = savePath

	return nil
}

// Fetch retrieves a single defined Source and validates its integrity.
func (s *Source) Fetch(cache string) error {
	if err := ensureDir(os.MkdirAll, cache); err != nil {
		return err
	}

	err := s.validateSource(cache)
	if err != nil {
		return err
	}

	finfo, _ := os.Stat(s.savePath)
	if finfo != nil {
		return checkBlake2SumFromFile(s.savePath, s.Blake2)
	}

	if err = s.fetch(); err != nil {
		return err
	}

	if err := checkBlake2SumFromFile(s.savePath, s.Blake2); err != nil {
		return err
	}

	return nil
}

// FetchSources retrieves all defined Sources and validates their integrity.
func (s *Spec) FetchSources() []error {
	errors := make([]error, 0, len(s.Sources))

	for _, source := range s.Sources {
		source := source
		if source.httpclient == nil {
			source.httpclient = rhttp.NewClient()
		}

		if err := source.Fetch(s.SourceCache); err != nil {
			errors = append(errors, err)
		}
	}

	return errors
}
