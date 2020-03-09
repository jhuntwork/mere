package mere

import (
	"fmt"
	"testing"

	"github.com/stretchr/testify/assert"
)

// nolint funlen
/*
  The default length of 60 lines seems generally reasonable. But in this case, the concise
  nature of table driven unit tests alongside the goal of more complete coverage outweigh
  the goal of short function length.
*/
func TestNewSpecErrors(t *testing.T) {
	var newSpecTests = []struct {
		description string
		filename    string
		errMsg      string
	}{
		{
			description: "Should fail when provided spec file doesn't exist",
			filename:    "testdata/no_such_file",
			errMsg:      "open testdata/no_such_file: no such file or directory",
		},
		{
			description: "Should fail when spec file contains invalid YAML",
			filename:    "testdata/invalid_yaml.txt",
			errMsg:      "yaml: line 3: could not find expected ':'",
		},
		{
			description: "Should fail when spec file doesn't match the schema",
			filename:    "testdata/bad_spec.yaml",
			errMsg:      "spec failed validation: /release: type should be integer",
		},
		{
			description: "Should fail when spec file doesn't contain all required fields",
			filename:    "testdata/missing_spec.yaml",
			errMsg:      `spec failed validation: /: "version" value is required, /: "release" value is required`,
		},
		{
			description: "Should fail when spec file has unparseable template values",
			filename:    "testdata/bad_template_spec.yaml",
			errMsg:      `template: :1: unexpected "}" in operand`,
		},
		{
			description: "Should fail when spec file uses unknown fields as template values",
			filename:    "testdata/bad_fields_spec.yaml",
			errMsg:      `template: :1:2: executing "" at <.FakeField>: can't evaluate field FakeField in type *mere.Spec`,
		},
		{
			description: "Should fail when spec file has bad template data in the 'build' section",
			filename:    "testdata/bad_template_build_spec.yaml",
			errMsg:      `template: :1:17: executing "" at <.Versio>: can't evaluate field Versio in type *mere.Spec`,
		},
		{
			description: "Should fail when spec file has bad template data in the 'test' section",
			filename:    "testdata/bad_template_test_spec.yaml",
			errMsg:      `template: :1:17: executing "" at <.Versio>: can't evaluate field Versio in type *mere.Spec`,
		},
		{
			description: "Should fail when spec file has bad template data in the 'install' section",
			filename:    "testdata/bad_template_install_spec.yaml",
			errMsg:      `template: :1:17: executing "" at <.Versio>: can't evaluate field Versio in type *mere.Spec`,
		},
		{
			description: "Should fail when spec file has bad blake2 value",
			filename:    "testdata/invalid_blake2_spec.yaml",
			errMsg:      "spec failed validation: /sources/0/blake2: min length of 64 characters required: a",
		},
	}

	for _, tt := range newSpecTests {
		tt := tt
		t.Run(tt.description, func(t *testing.T) {
			assert := assert.New(t)
			_, err := NewSpec(tt.filename)
			assert.EqualError(err, tt.errMsg)
		})
	}
}

type badUnmarshal struct {
	count int
}

func (b *badUnmarshal) Marshal(interface{}) ([]byte, error) {
	return []byte{}, nil
}
func (b *badUnmarshal) Unmarshal([]byte, interface{}) error {
	if b.count > 0 {
		b.count--
		return nil
	}

	return fmt.Errorf("failed to Unmarshal")
}

func Test_validateSchema(t *testing.T) {
	var tests = []struct {
		description string
		errMsg      string
	}{
		{
			description: "errors from first Unmarshal should fail the validation",
			errMsg:      "failed to Unmarshal",
		},
		{
			description: "errors from second Unmarshal should fail the validation",
			errMsg:      "failed to Unmarshal",
		},
	}

	for idx, tt := range tests {
		tt := tt
		idx := idx

		t.Run(tt.description, func(t *testing.T) {
			assert := assert.New(t)
			spec := Spec{}
			err := spec.validateSchema("testdata/spec.yaml", &badUnmarshal{count: idx})
			assert.EqualError(err, tt.errMsg)
		})
	}
}
