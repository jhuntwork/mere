package mere

import (
	"testing"

	"github.com/stretchr/testify/assert"
)

func TestNewSpec(t *testing.T) {
	var newSpecTests = []struct {
		desc      string
		filename  string
		shouldErr bool
		errMsg    string
	}{
		{
			"A good spec shouldn't fail",
			"testdata/spec.yaml",
			false,
			"",
		},
		{
			"Should fail when provided spec file doesn't exist",
			"testdata/no_such_file",
			true,
			"open testdata/no_such_file: no such file or directory",
		},
		{
			"Should fail when spec file contains invalid YAML",
			"testdata/invalid_yaml.txt",
			true,
			"yaml: line 3: could not find expected ':'",
		},
		{
			"Should fail when spec file doesn't match the schema",
			"testdata/bad_spec.yaml",
			true,
			"spec failed validation: /release: type should be integer",
		},
		{
			"Should fail when spec file doesn't contain all required fields",
			"testdata/missing_spec.yaml",
			true,
			`spec failed validation: /: "version" value is required, /: "release" value is required`,
		},
		{
			"Should fail when spec file has unparseable template values",
			"testdata/bad_template_spec.yaml",
			true,
			`template: :1: unexpected "}" in operand`,
		},
		{
			"Should fail when spec file uses unknown fields as template values",
			"testdata/bad_fields_spec.yaml",
			true,
			`template: :1:2: executing "" at <.FakeField>: can't evaluate field FakeField in type *mere.Spec`,
		},
		{
			"Should fail when spec file has bad template data in the 'build' section",
			"testdata/bad_template_build_spec.yaml",
			true,
			`template: :1:17: executing "" at <.Versio>: can't evaluate field Versio in type *mere.Spec`,
		},
		{
			"Should fail when spec file has bad template data in the 'test' section",
			"testdata/bad_template_test_spec.yaml",
			true,
			`template: :1:17: executing "" at <.Versio>: can't evaluate field Versio in type *mere.Spec`,
		},
		{
			"Should fail when spec file has bad template data in the 'install' section",
			"testdata/bad_template_install_spec.yaml",
			true,
			`template: :1:17: executing "" at <.Versio>: can't evaluate field Versio in type *mere.Spec`,
		},
		{
			"Should fail when spec file has bad blake2 value",
			"testdata/invalid_blake2_spec.yaml",
			true,
			"spec failed validation: /sources/0/blake2: min length of 128 characters required: a",
		},
	}
	for _, tt := range newSpecTests {
		tt := tt
		t.Run(tt.desc, func(t *testing.T) {
			assert := assert.New(t)
			_, err := NewSpec(tt.filename)
			if tt.shouldErr {
				assert.EqualError(err, tt.errMsg)
			} else {
				assert.NoError(err)
			}
		})
	}
}
