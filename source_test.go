package mere

import (
	"bytes"
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

func (*badReader) Read([]byte) (int, error) {
	return 0, fmt.Errorf("this is a mock failure")
}

func TestComputeBlake2(t *testing.T) {
	var computeBlake2Tests = []struct {
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
			expected:    "7cb98c9f584b1b9aae64e4c069d6d0b584d3fdb673e03c6478ae06cd15141acd",
		},
		{
			description: "should fail when cannot read from file",
			shouldErr:   true,
			errMsg:      "this is a mock failure",
		},
	}

	for _, tt := range computeBlake2Tests {
		tt := tt
		t.Run(tt.description, func(t *testing.T) {
			assert := assert.New(t)
			var err error
			if tt.filename != "" {
				tt.reader, err = os.Open(tt.filename)
				if err != nil {
					t.Errorf("Unable to open %s", tt.filename)
				}
			} else {
				tt.reader = &badReader{}
			}
			sum, err := ComputeBlake2(tt.reader)
			if tt.shouldErr {
				assert.EqualError(err, tt.errMsg)
			} else {
				assert.NoError(err)
				assert.Equal(tt.expected, sum)
			}
		})
	}
}

func Test_computeBlake2FromFile(t *testing.T) {
	t.Run("should fail if given a bad file", func(t *testing.T) {
		assert := assert.New(t)
		output, err := computeBlake2FromFile("testdata/no_such_file")
		assert.Equal("", output)
		assert.EqualError(err, "open testdata/no_such_file: no such file or directory")
	})
}

func badMkdirAll(string, os.FileMode) error {
	return fmt.Errorf("MkdirAll failed")
}

func Test_ensureDir(t *testing.T) {
	t.Run("should fail if directory is a file", func(t *testing.T) {
		assert := assert.New(t)
		spec, _ := NewSpec("testdata/spec.yaml")
		spec.SourceCache = "testdata/spec.yaml"
		err := ensureDir(os.MkdirAll, spec.SourceCache)
		assert.EqualError(err, "testdata/spec.yaml exists but is not a directory")
	})
	t.Run("should fail if directory cannot be created", func(t *testing.T) {
		assert := assert.New(t)
		spec, _ := NewSpec("testdata/spec.yaml")
		spec.SourceCache = "testdata/src/test"
		err := ensureDir(badMkdirAll, spec.SourceCache)
		assert.EqualError(err, "MkdirAll failed")
	})
	t.Run("should create a directory if it doesn't exist", func(t *testing.T) {
		dir := "testdata/src"
		os.RemoveAll(dir)
		assert := assert.New(t)
		spec, _ := NewSpec("testdata/spec.yaml")
		spec.SourceCache = dir
		defer os.RemoveAll(dir)
		err := ensureDir(os.MkdirAll, spec.SourceCache)
		assert.NoError(err)
		finfo, err := os.Stat(dir)
		assert.NoError(err)
		assert.NotNil(finfo)
	})
}

type badHTTP struct{}
type serverErrHTTP struct{}
type goodHTTP struct{}

func (s *serverErrHTTP) Get(string) (*http.Response, error) {
	var resp http.Response
	resp.StatusCode = 500
	resp.Body = ioutil.NopCloser(bytes.NewBufferString(""))

	return &resp, nil
}

func (b *badHTTP) Get(string) (*http.Response, error) {
	var resp http.Response
	return &resp, fmt.Errorf("transit error")
}

func (g *goodHTTP) Get(string) (*http.Response, error) {
	var resp http.Response
	resp.StatusCode = 200
	resp.Body = ioutil.NopCloser(bytes.NewBufferString("content"))

	return &resp, nil
}

func Test_fetchHttp(t *testing.T) {
	t.Run("should fail if there is an http error", func(t *testing.T) {
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
		assert := assert.New(t)
		spec, _ := NewSpec("testdata/spec.yaml")
		spec.Sources[0].savePath = "testdata/test2"
		spec.Sources[0].httpclient = &serverErrHTTP{}
		err := spec.Sources[0].fetchHTTP()
		if err == nil {
			t.Error("expected an error but did not receive one")
		}
		assert.EqualError(err, "Internal Server Error")
	})
	t.Run("should fail when unable to open a file for writing", func(t *testing.T) {
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

func Test_checkBlake2SumFromFile(t *testing.T) {
	t.Run("should not fail when file sum matches", func(t *testing.T) {
		assert := assert.New(t)
		err := checkBlake2SumFromFile(
			"testdata/spec.yaml",
			"7cb98c9f584b1b9aae64e4c069d6d0b584d3fdb673e03c6478ae06cd15141acd")
		assert.Nil(err)
	})
	t.Run("should fail when given a bad file", func(t *testing.T) {
		assert := assert.New(t)
		os.RemoveAll("testdata/src")
		err := checkBlake2SumFromFile(
			"testdata/src/spec.yaml",
			"not_a_blake2_sum")
		assert.EqualError(err, "open testdata/src/spec.yaml: no such file or directory")
	})
}

type sourceTest struct {
	description  string
	preExistFile bool
	url          string
	blake2       string
	sourceCache  string
	localName    string
	errMsg       string
	client       getter
}

func setupSource(t *testing.T, tt sourceTest, filePath string) (func(t *testing.T), *Spec) {
	spec, _ := NewSpec("testdata/spec.yaml")
	spec.SourceCache = tt.sourceCache

	if tt.preExistFile {
		if err := os.MkdirAll(spec.SourceCache, 0755); err != nil {
			return func(*testing.T) {
				t.Error(err)
			}, spec
		}

		if err := ioutil.WriteFile(filePath, []byte("Blah blah blah"), 0644); err != nil {
			return func(*testing.T) {
				t.Error(err)
			}, spec
		}
	}

	return func(t *testing.T) {
		if strings.Contains(spec.SourceCache, "testdata") {
			os.RemoveAll(spec.SourceCache)
		}
	}, spec
}

// nolint funlen
/*
  The default length of 60 lines seems generally reasonable. But in this case, the concise
  nature of table driven unit tests alongside the goal of more complete coverage outweigh
  the goal of short function length.
*/
func TestFetchSource(t *testing.T) {
	var fetchSourceTests = []sourceTest{
		{
			description: "should error if URL is unparseable",
			url:         "://blergh",
			sourceCache: "testdata/src",
			errMsg:      "missing protocol scheme",
			client:      &goodHTTP{},
		},
		{
			description: "should error if URL has no scheme",
			url:         "blergh",
			sourceCache: "testdata/src",
			errMsg:      "missing protocol scheme",
			client:      &goodHTTP{},
		},
		{
			description: "should error if URL.Scheme is unsupported",
			url:         "gxp://blergh/blargh",
			sourceCache: "testdata/src",
			errMsg:      "unsupported protocol scheme: gxp",
			client:      &goodHTTP{},
		},
		{
			description: "if there is no path provided it should error",
			url:         "https://blergh",
			sourceCache: "testdata/src",
			errMsg:      "no path element detected",
			client:      &goodHTTP{},
		},
		{
			description:  "if file exists but has the wrong sum it should error",
			preExistFile: true,
			url:          "https://blergh/blargh",
			blake2:       "not_a_valid_blake2_sum",
			sourceCache:  "testdata/src",
			localName:    "blargh",
			errMsg:       "blake2 sum mismatch",
			client:       &goodHTTP{},
		},
		{
			description: "http errors should cause it to fail",
			url:         "https://blergh/blargh",
			blake2:      "2d49316473cb68324b3f807c6d88c5618f6a422801f52ee3f6b3c29784504fc0",
			sourceCache: "testdata/src",
			localName:   "blargh",
			errMsg:      "transit error",
			client:      &badHTTP{},
		},
		{
			description: "after successful download, should check blake2 sum again",
			url:         "https://blergh/blargh",
			blake2:      "not_a_valid_blake2_sum",
			sourceCache: "testdata/src",
			localName:   "blargh",
			errMsg:      "blake2 sum mismatch",
			client:      &goodHTTP{},
		},
		{
			description: "after successful download, should check blake2 sum again, but succeed",
			url:         "https://blergh/blargh",
			blake2:      "2d49316473cb68324b3f807c6d88c5618f6a422801f52ee3f6b3c29784504fc0",
			sourceCache: "testdata/src",
			localName:   "blargh",
			client:      &goodHTTP{},
		},
		{
			description: "if the source cache directory cannot be created it should error",
			url:         "https://blergh/blargh",
			blake2:      "2d49316473cb68324b3f807c6d88c5618f6a422801f52ee3f6b3c29784504fc0",
			sourceCache: "/etc/resolv.conf/src",
			localName:   "blargh",
			errMsg:      "/etc/resolv.conf/src: not a directory",
			client:      &goodHTTP{},
		},
	}

	for _, tt := range fetchSourceTests {
		tt := tt
		t.Run(tt.description, func(t *testing.T) {
			assert := assert.New(t)
			filePath := strings.Join([]string{tt.sourceCache, tt.localName}, "/")
			tearDown, spec := setupSource(t, tt, filePath)
			defer tearDown(t)
			source := Source{
				URL:        tt.url,
				Blake2:     tt.blake2,
				LocalName:  tt.localName,
				httpclient: tt.client,
			}
			err := source.Fetch(spec.SourceCache)
			if tt.errMsg != "" {
				if err == nil {
					t.Errorf("expected an error but didn't receive one")
				} else {
					assert.Contains(err.Error(), tt.errMsg)
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

func TestFetchSources(t *testing.T) {
	t.Run("testing multiple sources", func(t *testing.T) {
		assert := assert.New(t)
		spec, _ := NewSpec("testdata/spec.yaml")
		spec.Sources = []Source{
			{
				URL:       "://blergh",
				Blake2:    "not_a_valid_blake2_sum",
				LocalName: "blergh",
			},
			{
				URL:        "https://blargh/blergh",
				LocalName:  "blergh",
				httpclient: &goodHTTP{},
			},
		}
		errors := spec.FetchSources()
		assert.Len(errors, 2)
	})
}
