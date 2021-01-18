package mere_test

import (
	"bytes"
	"testing"

	"github.com/jhuntwork/mere"
	"github.com/stretchr/testify/assert"
)

//nolint:funlen
/*
  The default length of 60 lines seems generally reasonable. But in this case, the concise
  nature of table driven unit tests alongside the goal of more complete coverage outweigh
  the goal of short function length.
*/
func TestNewSpecErrors(t *testing.T) {
	t.Parallel()
	newSpecTests := []struct {
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
			filename:    "testdata/bad_yaml.txt",
			errMsg:      "yaml: line 2: could not find expected ':'",
		},
		{
			description: "Should fail when spec file doesn't match the schema",
			filename:    "testdata/bad_spec.yaml",
			errMsg:      "invalid spec file: testdata/bad_spec.yaml\n\trelease: Invalid type. Expected: integer, given: string",
		},
		{
			description: "Should fail when spec file doesn't contain all required fields",
			filename:    "testdata/bad_template_missing_fields_spec.yaml",
			errMsg: "invalid spec file: testdata/bad_template_missing_fields_spec.yaml\n\t(root): " +
				"version is required\n\t(root): release is required",
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
			description: "Should fail when spec file has bad b3sum value",
			filename:    "testdata/bad_b3sum_spec.yaml",
			errMsg: "invalid spec file: testdata/bad_b3sum_spec.yaml\n\tsources.0.b3sum: " +
				"String length must be greater than or equal to 64",
		},
		{
			description: "Should fail when spec source uses an invalid url scheme",
			filename:    "testdata/bad_url.yaml",
			errMsg:      `parse "://fake/file": missing protocol scheme`,
		},
	}
	for _, tc := range newSpecTests {
		tc := tc
		t.Run(tc.description, func(t *testing.T) {
			t.Parallel()
			assert := assert.New(t)
			var buf bytes.Buffer
			_, err := mere.NewSpec(tc.filename, &buf)
			assert.Contains(err.Error(), tc.errMsg)
		})
	}
}

func TestBuildSteps(t *testing.T) {
	t.Parallel()
	t.Run("Should execute a build stage", func(t *testing.T) {
		t.Parallel()
		var buf bytes.Buffer
		assert := assert.New(t)
		spec, err := mere.NewSpec("testdata/spec_no_sources.yaml", &buf)
		assert.Nil(err)
		err = spec.BuildSteps()
		defer spec.Cleanup()
		assert.NoError(err)
	})
}
