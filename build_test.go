package mere

import (
	"errors"
	"fmt"
	"io/ioutil"
	"os"
	"testing"

	"github.com/stretchr/testify/assert"
)

var (
	errTempDir = errors.New("failure running TempDir")
	errSymlink = errors.New("failure running Symlink")
)

func badTempDir(string, string) (string, error) {
	return "", fmt.Errorf("%w", errTempDir)
}

func badSymlink(string, string) error {
	return fmt.Errorf("%w", errSymlink)
}

func badTempDirNoError(string, string) (string, error) {
	return "testdata/no-such-file", nil
}

func mockFetchSources(sources []Source, cache string, fn transportCreator) []error {
	return nil
}

func mockBadFetchSources(sources []Source, cache string, fn transportCreator) []error {
	return []error{fmt.Errorf("%w", errFetchSources)}
}

func Test_createWorkingDir(t *testing.T) {
	t.Run("should return an error if the system call to TempDir fails", func(t *testing.T) {
		assert := assert.New(t)
		spec, err := NewSpec("testdata/spec.yaml")
		assert.Nil(err)
		spec.tempDirFunc = badTempDir
		_, err = spec.createWorkingDir()
		assert.EqualError(err, "failure running TempDir")
	})
	t.Run("should return an error if unable to create new directories inside the tempdir", func(t *testing.T) {
		assert := assert.New(t)
		spec, err := NewSpec("testdata/spec.yaml")
		assert.Nil(err)
		spec.tempDirFunc = badTempDirNoError
		_, err = spec.createWorkingDir()
		assert.EqualError(err, "mkdir testdata/no-such-file/build: no such file or directory")
	})
}

//nolint:funlen
func TestBuildSteps(t *testing.T) {
	buildStepsTests := []struct {
		description  string
		filename     string
		errMsg       string
		tempDir      func(string, string) (string, error)
		symlink      func(string, string) error
		fetchSources func([]Source, string, transportCreator) []error
		extractFail  bool
	}{
		{
			description:  "Should fetch sources",
			filename:     "testdata/spec.yaml",
			errMsg:       "",
			tempDir:      ioutil.TempDir,
			symlink:      os.Symlink,
			fetchSources: mockFetchSources,
			extractFail:  false,
		},
		{
			description:  "Should return an error when extracting an archive fails",
			filename:     "testdata/spec.yaml",
			errMsg:       "open testdata/no-such-file: no such file or directory",
			tempDir:      ioutil.TempDir,
			symlink:      os.Symlink,
			fetchSources: mockFetchSources,
			extractFail:  true,
		},
		{
			description:  "Should fail when fetchSources fails",
			filename:     "testdata/bad_url.yaml",
			errMsg:       "build error: [failure running fetchSources]",
			tempDir:      ioutil.TempDir,
			symlink:      os.Symlink,
			fetchSources: mockBadFetchSources,
			extractFail:  false,
		},
		{
			description:  "Should return an error when the call to TempDir fails",
			filename:     "testdata/spec.yaml",
			errMsg:       "failure running TempDir",
			tempDir:      badTempDir,
			symlink:      os.Symlink,
			fetchSources: mockFetchSources,
			extractFail:  false,
		},
		{
			description:  "Should return an error when the build command fails",
			filename:     "testdata/spec_with_build_errors.yaml",
			errMsg:       "exit status 1",
			tempDir:      ioutil.TempDir,
			symlink:      os.Symlink,
			fetchSources: mockFetchSources,
			extractFail:  false,
		},
		{
			description:  "Should return an error when unable to create symlinks to sources",
			filename:     "testdata/spec.yaml",
			errMsg:       "failure running Symlink",
			tempDir:      ioutil.TempDir,
			symlink:      badSymlink,
			fetchSources: mockFetchSources,
			extractFail:  false,
		},
	}
	for _, test := range buildStepsTests {
		test := test
		t.Run(test.description, func(t *testing.T) {
			assert := assert.New(t)
			spec, err := NewSpec(test.filename)
			assert.Nil(err)
			spec.sourcesFunc = test.fetchSources
			spec.tempDirFunc = test.tempDir
			spec.symlinkFunc = test.symlink
			spec.Sources[0].savePath = "testdata/testarchive.tar.gz"
			if test.extractFail {
				spec.Sources[0].savePath = "testdata/no-such-file"
			}
			err = spec.BuildSteps()
			defer os.RemoveAll(spec.workingDir)
			if test.errMsg == "" {
				assert.NoError(err)
			} else {
				assert.EqualError(err, test.errMsg)
			}
		})
	}
}
