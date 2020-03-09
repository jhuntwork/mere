package mere

import (
	"bytes"
	"fmt"
	"io/ioutil"
	"os/user"
	"text/template"

	"github.com/alecthomas/jsonschema"
	"github.com/ghodss/yaml"
	jsoniter "github.com/json-iterator/go"
	validate "github.com/qri-io/jsonschema"
)

// Package defines the properties needed to create an individual package.
type Package struct {
	Name  string   `json:"name"`
	Deps  []string `json:"deps,omitempty"`
	Files []string `json:"files,omitempty"`
}

// Spec contains the properties needed to build one or more packages
// from the same source code.
type Spec struct {
	Name        string    `json:"name"`
	Description string    `json:"description"`
	Home        string    `json:"home"`
	Version     string    `json:"version"`
	Release     int64     `json:"release"`
	Sources     []Source  `json:"sources"`
	SourceCache string    `json:"sourceCache,omitempty"`
	BuildDeps   string    `json:"buildDeps,omitempty"`
	Build       string    `json:"build,omitempty"`
	Test        string    `json:"test,omitempty"`
	Install     string    `json:"install,omitempty"`
	Packages    []Package `json:"packages"`
}

func (s *Spec) render(v string) (string, error) {
	tl, err := template.New("").Parse(v)
	if err != nil {
		return "", err
	}

	buf := new(bytes.Buffer)
	if err = tl.Execute(buf, s); err != nil {
		return "", err
	}

	return buf.String(), nil
}

func (s *Spec) renderAll() error {
	var err error

	// render values for possible template strings of specific fields.
	// Currently supported: sources[].url, packages[].files[], build, test and install.
	for i := 0; i < len(s.Sources); i++ {
		if s.Sources[i].URL, err = s.render(s.Sources[i].URL); err != nil {
			return err
		}
	}

	for i := 0; i < len(s.Packages); i++ {
		for ii := 0; ii < len(s.Packages[i].Files); ii++ {
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
	reflector := new(jsonschema.Reflector)
	reflector.ExpandedStruct = true
	rs := &validate.RootSchema{}
	schema := reflector.Reflect(&Spec{})

	schemaBytes, _ := json.Marshal(schema)
	if err := json.Unmarshal(schemaBytes, rs); err != nil {
		return err
	}

	data, err := ioutil.ReadFile(path)
	if err != nil {
		return err
	}

	jsondata, err := yaml.YAMLToJSON(data)
	if err != nil {
		return err
	}

	// validate the data according to the schema
	if errors, err := rs.ValidateBytes(jsondata); err != nil || len(errors) > 0 {
		if err == nil {
			msg := "spec failed validation: "
			for i := 0; i < len(errors); i++ {
				msg = (msg + errors[i].PropertyPath + ": " + errors[i].Message)
				if i != (len(errors) - 1) {
					msg = (msg + ", ")
				}
			}

			err = fmt.Errorf(msg)
		}

		return err
	}

	if err := json.Unmarshal(jsondata, s); err != nil {
		return err
	}

	return nil
}

// NewSpec constructs and validates new Spec structs from a given file.
func NewSpec(path string) (*Spec, error) {
	spec := new(Spec)
	if err := spec.validateSchema(path, jsoniter.ConfigCompatibleWithStandardLibrary); err != nil {
		return nil, err
	}

	if err := spec.renderAll(); err != nil {
		return nil, err
	}

	if spec.SourceCache == "" {
		user, _ := user.Current()
		spec.SourceCache = user.HomeDir + "/.mere/src"
	}

	return spec, nil
}
