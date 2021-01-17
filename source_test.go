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

type badReader struct{}

const (
	// b3sum of testdata/spec.yaml.
	goodSpecB3Sum = "8c312c270003dd6c40fc01b048efc664308ecadf14c4bfcee7980fb59bed4d16"
	// output of goodHTTP.Get function.
	badSpecB3Sum = "3fba5250be9ac259c56e7250c526bc83bacb4be825f2799d3d59e5b4878dd74e"
	sourceCache  = "testdata/src"
)

var (
	errRead            = errors.New("this is a mock Read failure")
	errClose           = errors.New("this is a mock Close failure")
	errMkdirAll        = errors.New("failure when running MkdirAll")
	errTransit         = errors.New("transit error")
	errTranportCreator = errors.New("failure when creating transport")
)

func mockPrintHook(string) {}

func (*badReader) Read([]byte) (int, error) {
	return 0, fmt.Errorf("%w", errRead)
}

func (*badReader) Close() error {
	return fmt.Errorf("%w", errClose)
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
	t.Run("should fail if directory is a file", func(t *testing.T) {
		t.Parallel()
		assert := assert.New(t)
		spec, _ := NewSpec("testdata/spec.yaml")
		spec.sourceCache = "testdata/spec.yaml"
		err := ensureDir(os.MkdirAll, spec.sourceCache)
		assert.EqualError(err, "not a directory: testdata/spec.yaml")
	})
	t.Run("should fail if directory cannot be created", func(t *testing.T) {
		t.Parallel()
		assert := assert.New(t)
		spec, _ := NewSpec("testdata/spec.yaml")
		spec.sourceCache = sourceCache + "/test"
		err := ensureDir(badMkdirAll, spec.sourceCache)
		assert.EqualError(err, "failure when running MkdirAll")
	})
	t.Run("should create a directory if it doesn't exist", func(t *testing.T) {
		t.Parallel()
		dir := sourceCache
		os.RemoveAll(dir)
		assert := assert.New(t)
		spec, _ := NewSpec("testdata/spec.yaml")
		spec.sourceCache = dir
		defer os.RemoveAll(dir)
		err := ensureDir(os.MkdirAll, spec.sourceCache)
		assert.NoError(err)
		finfo, err := os.Stat(dir)
		assert.NoError(err)
		assert.NotNil(finfo)
	})
}

type (
	badHTTP         struct{}
	serverErrHTTP   struct{}
	goodHTTP        struct{}
	goodHTTPBadBody struct{}
)

func (s *serverErrHTTP) Get(string) (*http.Response, error) {
	var resp http.Response
	resp.StatusCode = 500
	resp.Body = ioutil.NopCloser(bytes.NewBufferString(""))

	return &resp, nil
}

func (b *badHTTP) Get(string) (*http.Response, error) {
	var resp http.Response

	return &resp, fmt.Errorf("%w", errTransit)
}

func (g *goodHTTP) Get(string) (*http.Response, error) {
	var resp http.Response
	resp.StatusCode = 200
	resp.Body = ioutil.NopCloser(bytes.NewBufferString("content"))

	return &resp, nil
}

func (g *goodHTTPBadBody) Get(string) (*http.Response, error) {
	var resp http.Response
	resp.StatusCode = 200
	resp.Body = &badReader{}

	return &resp, nil
}

func Test_fetchHtestp(t *testing.T) {
	t.Parallel()
	t.Run("should fail if there is an http error", func(t *testing.T) {
		t.Parallel()
		assert := assert.New(t)
		spec, _ := NewSpec("testdata/spec.yaml")
		spec.Sources[0].savePath = "testdata/test1"
		spec.Sources[0].httpclient = &badHTTP{}
		err := spec.Sources[0].fetchHTTP()
		if err == nil {
			t.Error("expected an error but did not receive one")
		}
		assert.Error(err)
	})
	t.Run("should fail if there is a server error", func(t *testing.T) {
		t.Parallel()
		assert := assert.New(t)
		spec, _ := NewSpec("testdata/spec.yaml")
		spec.Sources[0].savePath = "testdata/test2"
		spec.Sources[0].httpclient = &serverErrHTTP{}
		err := spec.Sources[0].fetchHTTP()
		if err == nil {
			t.Error("expected an error but did not receive one")
		}
		assert.EqualError(err, "download error: Internal Server Error")
	})
	t.Run("should fail when unable to open a file for writing", func(t *testing.T) {
		t.Parallel()
		assert := assert.New(t)
		spec, _ := NewSpec("testdata/spec.yaml")
		spec.Sources[0].savePath = "/dev/null/test3"
		spec.Sources[0].httpclient = &goodHTTP{}
		err := spec.Sources[0].fetchHTTP()
		if err == nil {
			t.Error("expected an error but did not receive one")
		}
		assert.EqualError(err, "open /dev/null/test3: not a directory")
	})
	t.Run("should not fail when content is successfully returned", func(t *testing.T) {
		t.Parallel()
		assert := assert.New(t)
		spec, _ := NewSpec("testdata/spec.yaml")
		tmpfile, err := ioutil.TempFile("", "")
		if err != nil {
			t.Error(err)
		}
		tmpfileName := tmpfile.Name()
		defer os.Remove(tmpfileName)
		spec.Sources[0].savePath = tmpfileName
		spec.Sources[0].httpclient = &goodHTTP{}
		err = spec.Sources[0].fetchHTTP()
		assert.NoError(err)
		actual, err := ioutil.ReadFile(tmpfileName)
		if err != nil {
			t.Error(err)
		}
		assert.Equal("content", string(actual))
	})
}

func Test_checkB3SumFromFile(t *testing.T) {
	t.Parallel()
	t.Run("should not fail when file sum matches", func(t *testing.T) {
		t.Parallel()
		assert := assert.New(t)
		source := Source{printHook: func(string) {}}
		err := source.checkB3SumFromFile(
			"testdata/spec.yaml",
			goodSpecB3Sum)
		assert.Nil(err)
	})
	t.Run("should fail when given a bad file", func(t *testing.T) {
		t.Parallel()
		assert := assert.New(t)
		os.RemoveAll(sourceCache)
		source := Source{printHook: func(string) {}}
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
	client       getter
}

func setupSource(t *testing.T, test sourceTest, filePath string) (func(t *testing.T), *Spec) {
	spec, _ := NewSpec("testdata/spec.yaml")
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
	fetchSourceTests := []sourceTest{
		{
			description: "should error if URL is unparseable",
			url:         "://blergh",
			errMsg:      "missing protocol scheme",
			client:      &goodHTTP{},
		},
		{
			description: "should error if URL has no scheme",
			url:         "blergh",
			errMsg:      "missing protocol scheme",
			client:      &goodHTTP{},
		},
		{
			description: "should error if URL.Scheme is unsupported",
			url:         "gxp://blergh/blargh",
			errMsg:      "unsupported protocol scheme: gxp",
			client:      &goodHTTP{},
		},
		{
			description: "if there is no path provided it should error",
			url:         "https://blergh",
			errMsg:      "no path element detected",
			client:      &goodHTTP{},
		},
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
			b3sum:       badSpecB3Sum,
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
			b3sum:       badSpecB3Sum,
			localName:   "blargh",
			client:      &goodHTTP{},
		},
		{
			description: "if the source cache directory cannot be created it should error",
			url:         "https://blergh/blargh",
			b3sum:       badSpecB3Sum,
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
	}
	for i, test := range fetchSourceTests {
		test := test
		i := i
		t.Run(test.description, func(t *testing.T) {
			t.Parallel()
			assert := assert.New(t)
			var name string
			if test.localName != "" {
				name = fmt.Sprintf("test%d", i)
			}
			if test.sourceCache == "" {
				test.sourceCache = fmt.Sprintf("%s%d", sourceCache, i)
			}
			filePath := strings.Join([]string{test.sourceCache, name}, "/")
			tearDown, spec := setupSource(t, test, filePath)
			defer tearDown(t)
			source := Source{
				URL:        test.url,
				B3Sum:      test.b3sum,
				LocalName:  name,
				httpclient: test.client,
				printHook:  mockPrintHook,
			}
			err := source.fetchSource(spec.sourceCache)
			if test.errMsg != "" {
				if err == nil {
					t.Errorf("expected an error but didn't receive one")
				} else {
					assert.Contains(err.Error(), test.errMsg)
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

func mockTransportCreator() (*http.Transport, error) {
	return &http.Transport{}, nil
}

func mockBadTransportCreator() (*http.Transport, error) {
	return &http.Transport{}, fmt.Errorf("%w", errTranportCreator)
}

func Test_fetchSources(t *testing.T) {
	t.Parallel()
	t.Run("testing multiple sources", func(t *testing.T) {
		t.Parallel()
		assert := assert.New(t)
		spec, _ := NewSpec("testdata/spec.yaml")
		spec.sourceCache = sourceCache
		defer os.RemoveAll(sourceCache)
		spec.Sources = []Source{
			{
				URL:       "://blergh",
				B3Sum:     "not_a_valid_b3sum_sum",
				LocalName: "blergh",
				printHook: mockPrintHook,
			},
			{
				URL:        "https://blargh/blergh",
				LocalName:  "blergh",
				httpclient: &goodHTTP{},
				printHook:  mockPrintHook,
			},
		}
		errors := fetchSources(spec.Sources, spec.sourceCache, mockTransportCreator)
		assert.Len(errors, len(spec.Sources))
	})
	t.Run("an error should be returned when a transport cannot be created", func(t *testing.T) {
		t.Parallel()
		assert := assert.New(t)
		spec, _ := NewSpec("testdata/spec.yaml")
		spec.sourceCache = sourceCache
		defer os.RemoveAll(sourceCache)
		spec.Sources = []Source{
			{
				URL:        "https://blargh/blergh",
				B3Sum:      "",
				LocalName:  "blergh",
				httpclient: &goodHTTP{},
				printHook:  mockPrintHook,
			},
		}
		errors := fetchSources(spec.Sources, spec.sourceCache, mockBadTransportCreator)
		assert.Len(errors, 1)
		assert.EqualError(errors[0], "failure when creating transport")
	})
}

func TestExtract(t *testing.T) {
	t.Parallel()
	t.Run("Should fail on missing archives", func(t *testing.T) {
		t.Parallel()
		assert := assert.New(t)
		source := Source{savePath: "testdata/no-such-file", printHook: mockPrintHook}
		err := source.extract("/tmp")
		assert.EqualError(err, "open testdata/no-such-file: no such file or directory")
	})
	t.Run("Should fail on bad archives", func(t *testing.T) {
		t.Parallel()
		assert := assert.New(t)
		source := Source{savePath: "testdata/spec.yaml", printHook: mockPrintHook}
		err := source.extract("/tmp")
		assert.EqualError(err, "Not a supported archive")
	})
	t.Run("Should extract good archives", func(t *testing.T) {
		t.Parallel()
		assert := assert.New(t)
		source := Source{savePath: "testdata/testarchive.tar.gz", printHook: mockPrintHook}
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
