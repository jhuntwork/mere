package mere

import (
	"bytes"
	"errors"
	"fmt"
	"io"
	"io/ioutil"
	"net/http"
	"os/user"
	"text/template"
	"time"

	"github.com/alecthomas/jsonschema"
	"github.com/ghodss/yaml"
	"github.com/jhuntwork/aia-transport-go"
	jsoniter "github.com/json-iterator/go"
	"github.com/xeipuuv/gojsonschema"
)

const (
	configDir = "/.mere"
	srcDir    = "/src"
	timeout   = 30
)

var errValidate = errors.New("invalid spec file")

// Package defines the properties needed to create an individual package.
type Package struct {
	Name  string   `json:"name"`
	Deps  []string `json:"deps,omitempty"`
	Files []string `json:"files,omitempty"`
}

// Spec contains the properties needed to build one or more packages
// from the same source code.
type Spec struct {
	Name         string    `json:"name"`
	Description  string    `json:"description"`
	Home         string    `json:"home"`
	Version      string    `json:"version"`
	Release      int64     `json:"release"`
	Sources      []Source  `json:"sources,omitempty"`
	BuildDeps    string    `json:"buildDeps,omitempty"`
	Build        string    `json:"build,omitempty"`
	Test         string    `json:"test,omitempty"`
	Install      string    `json:"install,omitempty"`
	Packages     []Package `json:"packages"`
	httpclient   getter
	sourceCache  string
	buildContext string
	workingDir   string
	buildOrder   []map[string]string
	output       io.Writer
}

func (s *Spec) render(v string) (string, error) {
	tl, err := template.New("").Parse(v)
	if err != nil {
		return "", fmt.Errorf("%w", err)
	}

	buf := new(bytes.Buffer)
	if err = tl.Execute(buf, s); err != nil {
		return "", fmt.Errorf("%w", err)
	}

	return buf.String(), nil
}

func (s *Spec) renderAll() error {
	var err error

	// render values for possible template strings of specific fields.
	// Currently supported: sources[].url, packages[].files[], build, test and install.
	for i := range s.Sources {
		if s.Sources[i].URL, err = s.render(s.Sources[i].URL); err != nil {
			return err
		}
	}

	for i := range s.Packages {
		for ii := range s.Packages[i].Files {
			if s.Packages[i].Files[ii], err = s.render(s.Packages[i].Files[ii]); err != nil {
				return err
			}
		}
	}

	if s.Build, err = s.render(s.Build); err != nil {
		return err
	}

	if s.Test, err = s.render(s.Test); err != nil {
		return err
	}

	if s.Install, err = s.render(s.Install); err != nil {
		return err
	}

	return nil
}

type jsonIterator interface {
	Marshal(interface{}) ([]byte, error)
	Unmarshal([]byte, interface{}) error
}

func (s *Spec) validateSchema(path string, json jsonIterator) error {
	// Create a reflector to build a JSON Schema from the Spec definition.
	reflector := new(jsonschema.Reflector)
	reflector.ExpandedStruct = true
	schema := gojsonschema.NewGoLoader(reflector.Reflect(&Spec{}))

	yamldata, err := ioutil.ReadFile(path)
	if err != nil {
		return fmt.Errorf("%w", err)
	}

	jsondata, err := yaml.YAMLToJSON(yamldata)
	if err != nil {
		return fmt.Errorf("%w", err)
	}

	data := gojsonschema.NewBytesLoader(jsondata)
	result, _ := gojsonschema.Validate(schema, data)

	if !result.Valid() {
		var msg string
		for idx, err := range result.Errors() {
			if idx > 0 {
				msg = fmt.Sprintf("%s\n\t%s", msg, err)
			} else {
				msg = err.String()
			}
		}

		return fmt.Errorf("%w: %s\n\t%s", errValidate, path, msg)
	}

	if err := json.Unmarshal(jsondata, s); err != nil {
		return fmt.Errorf("%w", err)
	}

	return nil
}

// NewSpec constructs and validates new Spec structs from a given file.
func NewSpec(path string, output io.Writer) (*Spec, error) {
	spec := new(Spec)
	if err := spec.validateSchema(path, jsoniter.ConfigCompatibleWithStandardLibrary); err != nil {
		return nil, err
	}

	if err := spec.renderAll(); err != nil {
		return nil, err
	}

	if spec.sourceCache == "" {
		user, _ := user.Current()
		spec.sourceCache = user.HomeDir + configDir + srcDir
	}

	for i := range spec.Sources {
		if err := spec.Sources[i].validateSource(); err != nil {
			return nil, fmt.Errorf("%w", err)
		}
		spec.Sources[i].output = output
		if spec.Sources[i].protocol == httpProto && spec.httpclient == nil {
			transport, _ := aia.NewTransport()
			spec.httpclient = &http.Client{
				Timeout:   time.Second * timeout,
				Transport: transport,
			}
		}
	}

	spec.buildOrder = []map[string]string{
		{
			"name": "build",
			"cmd":  spec.Build,
		},
		{
			"name": "test",
			"cmd":  spec.Test,
		},
		{
			"name": "install",
			"cmd":  spec.Install,
		},
	}

	spec.output = output

	return spec, nil
}
