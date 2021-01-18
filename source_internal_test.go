package mere

import (
	"bytes"
	"errors"
	"fmt"
	"io"
	"io/ioutil"
	"net/http"
	"os"
	"strings"
	"testing"

	"github.com/stretchr/testify/assert"
)

const (
	// b3sum of testdata/spec.yaml.
	goodSpecB3Sum = "8c312c270003dd6c40fc01b048efc664308ecadf14c4bfcee7980fb59bed4d16"
	// output of goodHTTP.Get function.
	goodHTTPB3Sum = "3fba5250be9ac259c56e7250c526bc83bacb4be825f2799d3d59e5b4878dd74e"
	fileB3Sum     = "b319b03ad4ff94817e3555791bb67df918cd86466fc14426d4a969d94ded5c37"
	sourceCache   = "testdata/src"
	goodBody      = "content"
)

var (
	errRead     = errors.New("this is a mock Read failure")
	errClose    = errors.New("this is a mock Close failure")
	errMkdirAll = errors.New("failure when running MkdirAll")
	errTransit  = errors.New("transit error")
)

type (
	badCopier       struct{}
	badReader       struct{}
	badHTTP         struct{}
	serverErrHTTP   struct{}
	goodHTTP        struct{}
	goodHTTPBadBody struct{}
)

func (badCopier) Copy(dst io.Writer, src io.Reader) (int64, error) {
	return 0, fmt.Errorf("%w", errRead)
}

func (*badReader) Read([]byte) (int, error) {
	return 0, fmt.Errorf("%w", errRead)
}

func (*badReader) Close() error {
	return fmt.Errorf("%w", errClose)
}

func (s *serverErrHTTP) Do(*http.Request) (*http.Response, error) {
	var resp http.Response
	resp.StatusCode = 500
	resp.Body = ioutil.NopCloser(bytes.NewBufferString(""))

	return &resp, nil
}

func (b *badHTTP) Do(*http.Request) (*http.Response, error) {
	var resp http.Response

	return &resp, fmt.Errorf("%w", errTransit)
}

func (g *goodHTTP) Do(*http.Request) (*http.Response, error) {
	var resp http.Response
	resp.StatusCode = 200
	resp.Body = ioutil.NopCloser(bytes.NewBufferString(goodBody))
	resp.ContentLength = int64(len(goodBody))

	return &resp, nil
}

func (g *goodHTTPBadBody) Do(*http.Request) (*http.Response, error) {
	var resp http.Response
	resp.StatusCode = 200
	resp.Body = &badReader{}

	return &resp, nil
}

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
		test := test
		t.Run(test.description, func(t *testing.T) {
			t.Parallel()
			assert := assert.New(t)
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
				assert.EqualError(err, test.errMsg)
			} else {
				assert.NoError(err)
				assert.Equal(test.expected, sum)
			}
		})
	}
}

func Test_computeB3SumFromFile(t *testing.T) {
	t.Parallel()
	t.Run("should fail if given a bad file", func(t *testing.T) {
		t.Parallel()
		assert := assert.New(t)
		output, err := computeB3SumFromFile("testdata/no_such_file")
		assert.Equal("", output)
		assert.EqualError(err, "open testdata/no_such_file: no such file or directory")
	})
}

func badMkdirAll(string, os.FileMode) error {
	return fmt.Errorf("%w", errMkdirAll)
}

func Test_ensureDir(t *testing.T) {
	t.Parallel()
	var buf bytes.Buffer
	t.Run("should fail if directory is a file", func(t *testing.T) {
		t.Parallel()
		assert := assert.New(t)
		spec, _ := NewSpec("testdata/spec.yaml", &buf)
		spec.sourceCache = "testdata/spec.yaml"
		err := ensureDir(os.MkdirAll, spec.sourceCache)
		assert.EqualError(err, "not a directory: testdata/spec.yaml")
	})
	t.Run("should fail if directory cannot be created", func(t *testing.T) {
		t.Parallel()
		assert := assert.New(t)
		spec, _ := NewSpec("testdata/spec.yaml", &buf)
		spec.sourceCache = sourceCache + "/test"
		err := ensureDir(badMkdirAll, spec.sourceCache)
		assert.EqualError(err, "failure when running MkdirAll")
	})
	t.Run("should create a directory if it doesn't exist", func(t *testing.T) {
		t.Parallel()
		dir := sourceCache
		os.RemoveAll(dir)
		assert := assert.New(t)
		spec, _ := NewSpec("testdata/spec.yaml", &buf)
		spec.sourceCache = dir
		defer os.RemoveAll(dir)
		err := ensureDir(os.MkdirAll, spec.sourceCache)
		assert.NoError(err)
		finfo, err := os.Stat(dir)
		assert.NoError(err)
		assert.NotNil(finfo)
	})
}

//nolint:funlen
func Test_fetchHTTP(t *testing.T) {
	tests := []struct {
		description string
		filename    string
		client      doer
		savePath    string
		errMsg      string
	}{
		{
			description: "should fail if there is an http error",
			filename:    "testdata/spec.yaml",
			client:      &badHTTP{},
			savePath:    "testdata/test1",
			errMsg:      "transit error",
		},
		{
			description: "should fail if there is a server error",
			filename:    "testdata/spec.yaml",
			client:      &serverErrHTTP{},
			savePath:    "testdata/test2",
			errMsg:      "download error: Internal Server Error",
		},
		{
			description: "should fail when unable to open a file for writing",
			filename:    "testdata/spec.yaml",
			client:      &goodHTTP{},
			savePath:    "/dev/null/test3",
			errMsg:      "open /dev/null/test3: not a directory",
		},
		{
			description: "should not fail typically",
			filename:    "testdata/spec.yaml",
			client:      &goodHTTP{},
			savePath:    "/dev/null",
		},
	}
	t.Parallel()
	for _, tc := range tests {
		tc := tc
		var buf bytes.Buffer
		t.Run(tc.description, func(t *testing.T) {
			t.Parallel()
			assert := assert.New(t)
			spec, _ := NewSpec(tc.filename, &buf)
			spec.Sources[0].savePath = tc.savePath
			err := spec.Sources[0].fetchHTTP(tc.client)
			if tc.errMsg != "" {
				if err == nil {
					t.Error("expected an error but did not receive one")
				}
				assert.EqualError(err, tc.errMsg)
			} else {
				assert.Nil(err)
			}
		})
	}
	t.Run("should not fail when content is successfully returned", func(t *testing.T) {
		t.Parallel()
		var buf bytes.Buffer
		assert := assert.New(t)
		spec, _ := NewSpec("testdata/spec.yaml", &buf)
		tmpfile, err := ioutil.TempFile("", "")
		if err != nil {
			t.Error(err)
		}
		tmpfileName := tmpfile.Name()
		defer os.Remove(tmpfileName)
		spec.Sources[0].savePath = tmpfileName
		err = spec.Sources[0].fetchHTTP(&goodHTTP{})
		assert.NoError(err)
		actual, err := ioutil.ReadFile(tmpfileName)
		if err != nil {
			t.Error(err)
		}
		assert.Equal("content", string(actual))
	})
}

func Test_fetchFile(t *testing.T) {
	tests := []struct {
		description string
		filename    string
		savePath    string
		srcPath     string
		errMsg      string
		copier      copier
	}{
		{
			description: "should fail if cannot open the source file",
			filename:    "testdata/spec_local_file.yaml",
			srcPath:     "/dev/null/no-such-file",
			errMsg:      "open /dev/null/no-such-file: not a directory",
			copier:      copywrapper{},
		},
		{
			description: "should fail if cannot open the destination file",
			filename:    "testdata/spec_local_file.yaml",
			savePath:    "/dev/null/no-such-file",
			errMsg:      "open /dev/null/no-such-file: not a directory",
			copier:      copywrapper{},
		},
		{
			description: "should fail if encountering an error while copying",
			filename:    "testdata/spec_local_file.yaml",
			errMsg:      errRead.Error(),
			copier:      badCopier{},
		},
	}
	t.Parallel()
	for _, tc := range tests {
		tc := tc
		var buf bytes.Buffer
		t.Run(tc.description, func(t *testing.T) {
			t.Parallel()
			assert := assert.New(t)
			spec, _ := NewSpec(tc.filename, &buf)
			tempdir, err := ioutil.TempDir("", "")
			assert.Nil(err)
			defer os.RemoveAll(tempdir)
			spec.sourceCache = tempdir
			if tc.savePath == "" {
				spec.Sources[0].savePath = strings.Join([]string{tempdir, "outfile"}, "/")
			} else {
				spec.Sources[0].savePath = tc.savePath
			}
			if tc.srcPath != "" {
				spec.Sources[0].srcPath = tc.srcPath
			}
			err = spec.Sources[0].fetchFile(tc.copier)
			if err == nil {
				t.Error("expected an error but did not receive one")
			}
			assert.EqualError(err, tc.errMsg)
		})
	}
}

func Test_checkB3SumFromFile(t *testing.T) {
	t.Parallel()
	t.Run("should not fail when file sum matches", func(t *testing.T) {
		t.Parallel()
		var buf bytes.Buffer
		assert := assert.New(t)
		source := Source{output: &buf}
		err := source.checkB3SumFromFile(
			"testdata/spec.yaml",
			goodSpecB3Sum)
		assert.Nil(err)
	})
	t.Run("should fail when given a bad file", func(t *testing.T) {
		t.Parallel()
		var buf bytes.Buffer
		assert := assert.New(t)
		os.RemoveAll(sourceCache)
		source := Source{output: &buf}
		err := source.checkB3SumFromFile(
			sourceCache+"/spec.yaml",
			"not_a_b3sum_sum")
		assert.EqualError(err, "open testdata/src/spec.yaml: no such file or directory")
	})
}

type sourceTest struct {
	description  string
	preExistFile bool
	url          string
	b3sum        string
	sourceCache  string
	localName    string
	errMsg       string
	srcPath      string
	client       doer
}

func setupsource(t *testing.T, test sourceTest, filePath string) (func(t *testing.T), *Spec) {
	var buf bytes.Buffer
	spec, _ := NewSpec("testdata/spec.yaml", &buf)
	if test.sourceCache == "" {
		test.sourceCache = sourceCache
	}
	spec.sourceCache = test.sourceCache

	if test.preExistFile {
		if err := os.MkdirAll(spec.sourceCache, 0o755); err != nil {
			return func(*testing.T) {
				t.Error(err)
			}, spec
		}

		if err := ioutil.WriteFile(filePath, []byte("Blah blah blah"), 0o600); err != nil {
			return func(*testing.T) {
				t.Error(err)
			}, spec
		}
	}

	return func(t *testing.T) {
		if strings.Contains(spec.sourceCache, "testdata") {
			os.RemoveAll(spec.sourceCache)
		}
	}, spec
}

//nolint:funlen
/*
  The default length of 60 lines seems generally reasonable. But in this case, the concise
  nature of table driven unit tests alongside the goal of more complete coverage outweigh
  the goal of short function length.
*/
func Test_fetchSource(t *testing.T) {
	t.Parallel()
	fetchsourceTests := []sourceTest{
		{
			description:  "if file exists but has the wrong sum it should error",
			preExistFile: true,
			url:          "https://blergh/blargh",
			b3sum:        "not_a_valid_b3sum_sum",
			localName:    "blargh",
			errMsg:       "b3sum mismatch",
			client:       &goodHTTP{},
		},
		{
			description: "http errors should cause it to fail",
			url:         "https://blergh/blargh",
			b3sum:       goodHTTPB3Sum,
			localName:   "blargh",
			errMsg:      "transit error",
			client:      &badHTTP{},
		},
		{
			description: "after successful download, should check b3sum again",
			url:         "https://blergh/blargh",
			b3sum:       "not_a_valid_b3sum_sum",
			localName:   "blargh",
			errMsg:      "b3sum mismatch",
			client:      &goodHTTP{},
		},
		{
			description: "after successful download, should check b3sum again, but succeed",
			url:         "https://blergh/blargh",
			b3sum:       goodHTTPB3Sum,
			localName:   "blargh",
			client:      &goodHTTP{},
		},
		{
			description: "if the source cache directory cannot be created it should error",
			url:         "https://blergh/blargh",
			b3sum:       goodHTTPB3Sum,
			sourceCache: "/dev/null/src",
			localName:   "blargh",
			errMsg:      "stat /dev/null/src: not a directory",
			client:      &goodHTTP{},
		},
		{
			description: "if body response fails during read, it should error",
			url:         "https://blergh/blargh",
			b3sum:       goodSpecB3Sum,
			localName:   "blargh",
			errMsg:      "this is a mock Read failure",
			client:      &goodHTTPBadBody{},
		},
		{
			description: "test using a local file",
			url:         "file://./testdata/testarchive.tar.gz",
			b3sum:       fileB3Sum,
			localName:   "blargh",
		},
		{
			description: "should fail when using a local file and fetchFile fails",
			url:         "file://./testdata/testarchive.tar.gz",
			b3sum:       fileB3Sum,
			srcPath:     "/dev/null/this-is-not-a-file",
			errMsg:      "not a directory",
		},
	}
	for i, tc := range fetchsourceTests {
		tc := tc
		i := i
		t.Run(tc.description, func(t *testing.T) {
			t.Parallel()
			assert := assert.New(t)
			var buf bytes.Buffer
			if tc.sourceCache == "" {
				tc.sourceCache = fmt.Sprintf("%s%d", sourceCache, i)
			}
			filePath := strings.Join([]string{tc.sourceCache, tc.localName}, "/")
			tearDown, spec := setupsource(t, tc, filePath)
			defer tearDown(t)
			source := Source{
				URL:       tc.url,
				B3Sum:     tc.b3sum,
				LocalName: tc.localName,
				savePath:  filePath,
				output:    &buf,
			}
			err := source.validateSource()
			if tc.srcPath != "" {
				source.srcPath = tc.srcPath
			}
			assert.Nil(err)
			spec.httpclient = tc.client
			err = source.fetchSource(spec)
			if tc.errMsg != "" {
				if err == nil {
					t.Errorf("expected an error but didn't receive one")
				} else {
					assert.Contains(err.Error(), tc.errMsg)
				}
			} else {
				assert.NoError(err)
				finfo, err := os.Stat(filePath)
				assert.Nil(err)
				assert.NotNil(finfo)
			}
		})
	}
}

func Test_validateSource(t *testing.T) {
	t.Parallel()
	tests := []struct {
		description string
		url         string
		errMsg      string
	}{
		{
			description: "should error if URL is unparseable",
			url:         "://blergh",
			errMsg:      "missing protocol scheme",
		},
		{
			description: "should error if URL has no scheme",
			url:         "blergh",
			errMsg:      "missing protocol scheme",
		},
		{
			description: "should error if URL.Scheme is unsupported",
			url:         "gxp://blergh/blargh",
			errMsg:      "unsupported protocol scheme: gxp",
		},
		{
			description: "if there is no path provided it should error",
			url:         "https://blergh",
			errMsg:      "no path element detected",
		},
	}
	for _, tc := range tests {
		tc := tc
		t.Run(tc.description, func(t *testing.T) {
			t.Parallel()
			assert := assert.New(t)
			source := Source{
				URL: tc.url,
			}
			err := source.validateSource()
			if tc.errMsg != "" {
				if err == nil {
					t.Errorf("expected an error but didn't receive one")
				} else {
					assert.Contains(err.Error(), tc.errMsg)
				}
			}
		})
	}
}

func Test_fetchSources(t *testing.T) {
	t.Parallel()
	t.Run("testing multiple sources", func(t *testing.T) {
		t.Parallel()
		var buf bytes.Buffer
		assert := assert.New(t)
		spec, _ := NewSpec("testdata/spec.yaml", &buf)
		spec.sourceCache = sourceCache
		defer os.RemoveAll(sourceCache)
		spec.Sources = []Source{
			{
				URL:       "://blergh",
				B3Sum:     "not_a_valid_b3sum_sum",
				LocalName: "blergh",
			},
			{
				URL:       "://blargh/blergh",
				LocalName: "blergh",
			},
		}
		errors := spec.fetchSources()
		assert.Len(errors, len(spec.Sources))
	})
}

func Test_extract(t *testing.T) {
	t.Parallel()
	t.Run("Should fail on missing archives", func(t *testing.T) {
		t.Parallel()
		var buf bytes.Buffer
		assert := assert.New(t)
		source := Source{savePath: "testdata/no-such-file", output: &buf}
		err := source.extract("/tmp")
		assert.EqualError(err, "open testdata/no-such-file: no such file or directory")
	})
	t.Run("Should fail on bad archives", func(t *testing.T) {
		t.Parallel()
		var buf bytes.Buffer
		assert := assert.New(t)
		source := Source{savePath: "testdata/spec.yaml", output: &buf}
		err := source.extract("/tmp")
		assert.EqualError(err, "Not a supported archive")
	})
	t.Run("Should extract good archives", func(t *testing.T) {
		t.Parallel()
		var buf bytes.Buffer
		assert := assert.New(t)
		source := Source{savePath: "testdata/testarchive.tar.gz", output: &buf}
		tmpDir, _ := ioutil.TempDir("", "testarchive-*")
		defer os.RemoveAll(tmpDir)
		err := source.extract(tmpDir)
		assert.NoError(err)
		assert.NotEqual(tmpDir, "")
		_, err = os.Stat(tmpDir + "/testdata/spec.yaml")
		assert.Nil(err)
		files, _ := ioutil.ReadDir(tmpDir)
		assert.Equal(len(files), 1)
	})
}
