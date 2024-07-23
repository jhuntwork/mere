package mere

import (
	"bytes"
	"errors"
	"fmt"
	"os"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

var (
	errTempDir = errors.New("failure running TempDir")
	errSymlink = errors.New("failure running Symlink")
)

type badTempDir struct{}

func (b badTempDir) tempdir(string, string) (string, error) {
	return "", fmt.Errorf("%w", errTempDir)
}

type badTempDirNoError struct{}

func (b badTempDirNoError) tempdir(string, string) (string, error) {
	return "testdata/no-such-file", nil
}

type badSymlink struct{}

func (b badSymlink) symlink(string, string) error {
	return fmt.Errorf("%w", errSymlink)
}

func Test_createWorkingDir(t *testing.T) {
	t.Parallel()
	var buf bytes.Buffer
	t.Run("should return an error if creating a tmpdir fails", func(t *testing.T) {
		t.Parallel()
		assert := assert.New(t)
		spec, err := NewSpec("testdata/spec.yaml", &buf)
		require.NoError(t, err)
		_, err = spec.createWorkingDir(badTempDir{})
		assert.EqualError(err, "failure running TempDir")
	})
	t.Run("should return an error if unable to create new directories inside the tempdir", func(t *testing.T) {
		t.Parallel()
		assert := assert.New(t)
		spec, err := NewSpec("testdata/spec.yaml", &buf)
		require.NoError(t, err)
		_, err = spec.createWorkingDir(badTempDirNoError{})
		assert.EqualError(err, "mkdir testdata/no-such-file/build: no such file or directory")
	})
}

//nolint:funlen
func Test_setupBuildSteps(t *testing.T) {
	t.Parallel()
	tests := []struct {
		description string
		filename    string
		errMsg      string
		tempDir     temper
		symlink     linker
		client      doer
		extractFail bool
	}{
		{
			description: "Should fetch sources",
			filename:    "testdata/spec_local_file.yaml",
			errMsg:      "",
			tempDir:     tempd{},
			symlink:     slink{},
		},
		{
			description: "Should return an error when extracting an archive fails",
			filename:    "testdata/spec_with_unextractable_archive.yaml",
			errMsg:      "Not a supported archive: unknown",
			tempDir:     tempd{},
			symlink:     slink{},
			extractFail: true,
			client:      &goodHTTP{},
		},
		{
			description: "Should fail when fetchSources fails",
			filename:    "testdata/spec.yaml",
			errMsg:      `build error: [received an HTTP error: 500 Internal Server Error]`,
			tempDir:     tempd{},
			symlink:     slink{},
			client:      &serverErrHTTP{},
		},
		{
			description: "Should return an error when the call to TempDir fails",
			filename:    "testdata/spec_local_file.yaml",
			errMsg:      "failure running TempDir",
			tempDir:     badTempDir{},
			symlink:     slink{},
		},
		{
			description: "Should return an error when unable to create symlinks to sources",
			filename:    "testdata/spec_local_file.yaml",
			errMsg:      "failure running Symlink",
			tempDir:     tempd{},
			symlink:     badSymlink{},
		},
	}
	for _, tc := range tests {
		var buf bytes.Buffer
		t.Run(tc.description, func(t *testing.T) {
			t.Parallel()
			assert := assert.New(t)
			spec, err := NewSpec(tc.filename, &buf)
			require.NoError(t, err)
			tempdir, err := os.MkdirTemp("", "")
			require.NoError(t, err)
			defer os.RemoveAll(tempdir)
			spec.sourceCache = tempdir
			spec.httpclient = tc.client

			err = spec.setupBuildSteps(tc.tempDir, tc.symlink)
			defer spec.Cleanup()
			if tc.errMsg == "" {
				assert.NoError(err)
			} else {
				assert.EqualError(err, tc.errMsg)
			}
		})
	}
}

func Test_buildSteps(t *testing.T) {
	t.Parallel()
	tests := []struct {
		description string
		filename    string
		errMsg      string
		extractFail bool
	}{
		{
			description: "Should return an error when extracting an archive fails",
			filename:    "testdata/spec_with_unextractable_archive.yaml",
			errMsg:      "Not a supported archive: unknown",
			extractFail: true,
		},
		{
			description: "Should return an error when the build command fails",
			filename:    "testdata/spec_with_build_errors.yaml",
			errMsg:      "exit status 1",
		},
	}
	for _, tc := range tests {
		var buf bytes.Buffer
		t.Run(tc.description, func(t *testing.T) {
			t.Parallel()
			assert := assert.New(t)
			spec, err := NewSpec(tc.filename, &buf)
			require.NoError(t, err)
			tempdir, err := os.MkdirTemp("", "")
			require.NoError(t, err)
			defer os.RemoveAll(tempdir)
			spec.sourceCache = tempdir
			spec.httpclient = &goodHTTP{}

			err = spec.buildSteps()
			defer spec.Cleanup()
			if tc.errMsg == "" {
				assert.NoError(err)
			} else {
				assert.EqualError(err, tc.errMsg)
			}
		})
	}
}
