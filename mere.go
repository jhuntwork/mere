package mere

import (
	"bytes"
	"errors"
	"fmt"
	"io/ioutil"
	"os"
	"os/user"
	"text/template"

	"github.com/alecthomas/jsonschema"
	"github.com/ghodss/yaml"
	jsoniter "github.com/json-iterator/go"
	"github.com/xeipuuv/gojsonschema"
)

const (
	configDir = "/.mere"
	srcDir    = "/src"
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
	Sources      []Source  `json:"sources"`
	BuildDeps    string    `json:"buildDeps,omitempty"`
	Build        string    `json:"build,omitempty"`
	Test         string    `json:"test,omitempty"`
	Install      string    `json:"install,omitempty"`
	Packages     []Package `json:"packages"`
	sourceCache  string
	buildContext string
	workingDir   string
	buildOrder   []map[string]string
	printHook    func(string)
	tempDirFunc  func(string, string) (string, error)
	symlinkFunc  func(string, string) error
	sourcesFunc  func([]Source, string, transportCreator) []error
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

// SetPrintHook sets a function to use as a callback for handling output.
// The default hook is essentially a no-op.
func (s *Spec) SetPrintHook(fn func(string)) {
	s.printHook = fn
	for idx := range s.Sources {
		s.Sources[idx].printHook = fn
	}
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

	if spec.sourceCache == "" {
		user, _ := user.Current()
		spec.sourceCache = user.HomeDir + configDir + srcDir
	}
	spec.tempDirFunc = ioutil.TempDir
	spec.symlinkFunc = os.Symlink
	spec.SetPrintHook(func(output string) {})
	spec.sourcesFunc = fetchSources
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
	return spec, nil
}
