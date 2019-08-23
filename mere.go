package mere

import (
	"bytes"
	"encoding/json"
	"fmt"
	"io/ioutil"
	"os/user"
	"text/template"

	"github.com/alecthomas/jsonschema"
	"github.com/ghodss/yaml"
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

func render(v string, spec *Spec) (string, error) {
	tl, err := template.New("").Parse(v)
	if err != nil {
		return "", err
	}
	buf := new(bytes.Buffer)
	if err = tl.Execute(buf, spec); err != nil {
		return "", err
	}
	return buf.String(), nil
}

// NewSpec constructs and validates new Spec structs from a given file.
func NewSpec(path string) (*Spec, error) {
	spec := new(Spec)
	reflector := new(jsonschema.Reflector)
	reflector.ExpandedStruct = true
	rs := &validate.RootSchema{}
	schema := reflector.Reflect(&Spec{})
	schemaBytes, _ := json.Marshal(schema)
	if err := json.Unmarshal(schemaBytes, rs); err != nil {
		return nil, err
	}

	data, err := ioutil.ReadFile(path)
	if err != nil {
		return nil, err
	}
	jsondata, err := yaml.YAMLToJSON(data)
	if err != nil {
		return nil, err
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
		return nil, err
	}
	if err := json.Unmarshal(jsondata, spec); err != nil {
		return nil, err
	}

	// render values for possible template strings of specific fields.
	// Currently supported: sources[].url, packages[].files[], build, test and install.
	for i := 0; i < len(spec.Sources); i++ {
		if spec.Sources[i].URL, err = render(spec.Sources[i].URL, spec); err != nil {
			return nil, err
		}
	}
	for i := 0; i < len(spec.Packages); i++ {
		for ii := 0; ii < len(spec.Packages[i].Files); ii++ {
			if spec.Packages[i].Files[ii], err = render(spec.Packages[i].Files[ii], spec); err != nil {
				return nil, err
			}
		}
	}
	if spec.Build, err = render(spec.Build, spec); err != nil {
		return nil, err
	}
	if spec.Test, err = render(spec.Test, spec); err != nil {
		return nil, err
	}
	if spec.Install, err = render(spec.Install, spec); err != nil {
		return nil, err
	}
	if spec.SourceCache == "" {
		user, _ := user.Current()
		spec.SourceCache = user.HomeDir + "/.mere/src"
	}
	return spec, nil
}
