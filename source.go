package mere

import (
	"errors"
	"fmt"
	"io"
	"net/url"
	"os"
	"path"
	"path/filepath"
	"strings"
)

var (
	errHash   = errors.New("b3sum mismatch")
	errSource = errors.New("invalid source definition")
	errProto  = errors.New("unsupported or missing protocol scheme")
)

// Source defines the properties needed to retrieve and validate a source file.
type Source struct {
	URL       string `json:"url"`
	B3Sum     string `json:"b3sum"               jsonschema:"minLength=64,maxLength=64"`
	LocalName string `json:"localName,omitempty"`
	protocol  string
	savePath  string
	output    io.Writer
}

func (source *Source) validateSource() error {
	parsedURL, err := url.Parse(source.URL)
	if err != nil {
		return fmt.Errorf("%w", err)
	}

	switch parsedURL.Scheme {
	case "":
		fallthrough
	case fileProto:
		source.protocol = fileProto
	case httpProto, "https":
		source.protocol = httpProto
	default:
		return fmt.Errorf("%w: unsupported protocol scheme: %s", errSource, parsedURL.Scheme)
	}

	if source.LocalName == "" {
		source.LocalName = parsedURL.Path
	}

	testPath, _ := filepath.Abs("/" + path.Base(source.LocalName))
	if testPath == "/" {
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
		if err := fetchFile(copywrapper{}, source.LocalName, source.savePath); err != nil {
			return err
		}
	case httpProto:
		if err := fetchHTTP(spec.httpclient, source.URL, source.savePath); err != nil {
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
