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

	"github.com/sirupsen/logrus"
	"golang.org/x/crypto/blake2b"
)

// Source defines the properties needed to retrieve and validate a source file.
type Source struct {
	URL       string `json:"url"`
	Blake2    string `json:"blake2" jsonschema:"minLength=128,maxLength=128"`
	LocalName string `json:"localName,omitempty"`
}

type getter interface {
	Get(string) (*http.Response, error)
}

func (s *Spec) fetchHTTP(client getter, url string, localName string) error {
	resp, err := client.Get(url)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	if resp.StatusCode >= 400 {
		return fmt.Errorf("%s", http.StatusText(resp.StatusCode))
	}
	f, err := os.Create(localName)
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
	hash, _ := blake2b.New512(nil)
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

func (s *Spec) ensureSourceCache() error {
	finfo, err := os.Stat(s.SourceCache)
	if err != nil {
		if os.IsNotExist(err) {
			logrus.Debugf("Creating source cache directory: %s", s.SourceCache)
			if err := os.MkdirAll(s.SourceCache, 0755); err != nil {
				return err
			}
			return nil
		}
		return err
	}
	if !finfo.IsDir() {
		return fmt.Errorf("%s exists but is not a directory", s.SourceCache)
	}
	return nil
}

func (s *Spec) getLocalFilePath(p string) (string, error) {
	localName, _ := filepath.Abs(strings.Join([]string{s.SourceCache, path.Base(p)}, "/"))
	absSourcePath, _ := filepath.Abs(s.SourceCache)
	if localName == absSourcePath {
		return "", fmt.Errorf("no path element detected")
	}
	return localName, nil
}

func checkBlake2SumFromFile(filename string, blake2 string) error {
	sum, err := computeBlake2FromFile(filename)
	if err != nil {
		return err
	}
	if sum != blake2 {
		return fmt.Errorf(
			"file: %s, expected: %s, actual %s",
			path.Base(filename),
			blake2,
			sum)
	}
	return nil
}

// FetchSource retrieves a single defined Source and validates its integrity.
func (s *Spec) FetchSource(source *Source) error {
	var localName string
	var fetch func(string) error
	URL, err := url.Parse(source.URL)
	if err != nil {
		return err
	}
	switch URL.Scheme {
	case "http", "https":
		fetch = func(filename string) error {
			client := new(http.Client)
			return s.fetchHTTP(client, source.URL, filename)
		}
	case "":
		return fmt.Errorf("missing protocol scheme")
	default:
		return fmt.Errorf("unsupported protocol scheme: %s", URL.Scheme)
	}
	if err := s.ensureSourceCache(); err != nil {
		return err
	}
	if source.LocalName == "" {
		localName = URL.Path
	} else {
		localName = source.LocalName
	}
	localName, err = s.getLocalFilePath(localName)
	if err != nil {
		return err
	}
	finfo, _ := os.Stat(localName)
	if finfo != nil {
		if err := checkBlake2SumFromFile(localName, source.Blake2); err != nil {
			return err
		}
	}
	if err = fetch(localName); err != nil {
		return err
	}
	if err := checkBlake2SumFromFile(localName, source.Blake2); err != nil {
		return err
	}
	return nil
}

// FetchSources retrieves all defined Sources and validates their integrity.
func (s *Spec) FetchSources() []error {
	errors := make([]error, 0, len(s.Sources))
	for _, source := range s.Sources {
		source := source
		if err := s.FetchSource(&source); err != nil {
			errors = append(errors, err)
		}
	}
	return errors
}
