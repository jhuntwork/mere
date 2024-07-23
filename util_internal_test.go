package mere

import (
	"bytes"
	"errors"
	"fmt"
	"io"
	"os"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

const goodSpecB3Sum = "8c312c270003dd6c40fc01b048efc664308ecadf14c4bfcee7980fb59bed4d16"

func Test_computeB3Sum(t *testing.T) {
	t.Parallel()
	computeB3SumTests := []struct {
		description string
		shouldErr   bool
		filename    string
		reader      io.Reader
		expected    string
		errMsg      string
	}{
		{
			description: "should work on typical files",
			filename:    "testdata/spec.yaml",
			expected:    goodSpecB3Sum,
		},
		{
			description: "should fail when cannot read from file",
			shouldErr:   true,
			errMsg:      "this is a mock Read failure",
		},
	}
	for _, test := range computeB3SumTests {
		t.Run(test.description, func(t *testing.T) {
			t.Parallel()
			var err error
			if test.filename != "" {
				test.reader, err = os.Open(test.filename)
				if err != nil {
					t.Errorf("Unable to open %s", test.filename)
				}
			} else {
				test.reader = &badReader{}
			}
			sum, err := computeB3Sum(test.reader)
			if test.shouldErr {
				require.EqualError(t, err, test.errMsg)
			} else {
				require.NoError(t, err)
				require.Equal(t, test.expected, sum)
			}
		})
	}
}

func Test_checkB3SumFromFile(t *testing.T) {
	t.Parallel()
	t.Run("should not fail when file sum matches", func(t *testing.T) {
		t.Parallel()
		var buf bytes.Buffer
		source := Source{output: &buf}
		err := source.checkB3SumFromFile(
			"testdata/spec.yaml",
			goodSpecB3Sum)
		require.NoError(t, err)
	})
	t.Run("should fail when given a bad file", func(t *testing.T) {
		t.Parallel()
		var buf bytes.Buffer
		os.RemoveAll(sourceCache)
		source := Source{output: &buf}
		err := source.checkB3SumFromFile(
			sourceCache+"/spec.yaml",
			"not_a_b3sum_sum")
		require.EqualError(t, err, "open testdata/src/spec.yaml: no such file or directory")
	})
}

func Test_computeB3SumFromFile(t *testing.T) {
	t.Parallel()
	t.Run("should fail if given a bad file", func(t *testing.T) {
		t.Parallel()
		output, err := computeB3SumFromFile("testdata/no_such_file")
		require.Equal(t, "", output)
		require.EqualError(t, err, "open testdata/no_such_file: no such file or directory")
	})
}

var errMkdirAll = errors.New("failure when running MkdirAll")

func mockMkdirAll(string, os.FileMode) error {
	return fmt.Errorf("%w", errMkdirAll)
}

func Test_ensureDir(t *testing.T) {
	t.Parallel()
	t.Run("should fail if directory already exists as a file", func(t *testing.T) {
		t.Parallel()
		err := ensureDir(os.MkdirAll, "testdata/spec.yaml")
		require.Error(t, err)
		require.Equal(t, "not a directory: testdata/spec.yaml", err.Error())
	})
	t.Run("should fail if directory cannot be created", func(t *testing.T) {
		t.Parallel()
		err := ensureDir(mockMkdirAll, "testdata/test")
		require.Equal(t, "failure when running MkdirAll", err.Error())
	})
	t.Run("should fail if invalid location given", func(t *testing.T) {
		t.Parallel()
		err := ensureDir(mockMkdirAll, "/dev/null/test")
		require.Equal(t, "stat /dev/null/test: not a directory", err.Error())
	})
	t.Run("should return nil if directory exists", func(t *testing.T) {
		t.Parallel()
		err := ensureDir(mockMkdirAll, "testdata")
		require.NoError(t, err)
	})
	t.Run("should create a directory if it doesn't exist", func(t *testing.T) {
		t.Parallel()
		dir, _ := os.MkdirTemp("", "")
		defer os.RemoveAll(dir)
		err := ensureDir(os.MkdirAll, dir+"/new/new2/new3")
		require.NoError(t, err)
		finfo, err := os.Stat(dir)
		require.NoError(t, err)
		require.NotNil(t, finfo)
	})
}

func Test_extractArchive(t *testing.T) {
	t.Parallel()
	t.Run("Should fail on missing archives", func(t *testing.T) {
		t.Parallel()
		assert := assert.New(t)
		err := extractArchive("testdata/no-such-file", "/tmp")
		assert.EqualError(err, "open testdata/no-such-file: no such file or directory")
	})
	t.Run("Should fail on bad archives", func(t *testing.T) {
		t.Parallel()
		assert := assert.New(t)
		err := extractArchive("testdata/spec.yaml", "/tmp")
		assert.Contains(err.Error(), "Not a supported archive")
	})
	t.Run("Should extract good archives", func(t *testing.T) {
		t.Parallel()
		assert := assert.New(t)
		tmpDir, _ := os.MkdirTemp("", "testarchive-*")
		defer os.RemoveAll(tmpDir)
		err := extractArchive("testdata/testarchive.tar.gz", tmpDir)
		require.NoError(t, err)
		assert.NotEqual("", tmpDir)
		_, err = os.Stat(tmpDir + "/testdata/spec.yaml")
		require.NoError(t, err)
		files, _ := os.ReadDir(tmpDir)
		assert.Len(files, 1)
	})
}
