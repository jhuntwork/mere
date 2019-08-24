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
		desc      string
		filename  string
		reader    io.Reader
		shouldErr bool
		expected  string
		errMsg    string
	}{
		{
			"should work on typical files",
			"testdata/spec.yaml",
			nil,
			false,
			"b4fc6c456ba6c0405e2197b86ddb8d5cad819dbc5e67991a9cc3da85ae355dab" +
				"b0a3307b5e66970192d925c8abd4e02f0b7c7ac20fe21348d515b413f3ce4fd6",
			"",
		},
		{
			"should fail when cannot read from file",
			"",
			nil,
			true,
			"",
			"this is a mock failure",
		},
	}
	for _, tt := range computeBlake2Tests {
		tt := tt
		t.Run(tt.desc, func(t *testing.T) {
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

func Test_ensureSourceCache(t *testing.T) {
	t.Run("should fail if directory is a file", func(t *testing.T) {
		assert := assert.New(t)
		spec, _ := NewSpec("testdata/spec.yaml")
		spec.SourceCache = "testdata/spec.yaml"
		err := spec.ensureSourceCache()
		assert.Error(err)
		assert.EqualError(err, "testdata/spec.yaml exists but is not a directory")
	})
	t.Run("should create a directory if it doesn't exist", func(t *testing.T) {
		dir := "testdata/src"
		os.RemoveAll(dir)
		assert := assert.New(t)
		spec, _ := NewSpec("testdata/spec.yaml")
		spec.SourceCache = dir
		defer os.RemoveAll(dir)
		err := spec.ensureSourceCache()
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
		err := spec.fetchHTTP(&badHTTP{}, spec.Sources[0].URL, "testdata/test1")
		if err == nil {
			t.Error("expected an error but did not receive one")
		}
		assert.Error(err)
	})
	t.Run("should fail if there is a server error", func(t *testing.T) {
		assert := assert.New(t)
		spec, _ := NewSpec("testdata/spec.yaml")
		err := spec.fetchHTTP(&serverErrHTTP{}, spec.Sources[0].URL, "testdata/test2")
		if err == nil {
			t.Error("expected an error but did not receive one")
		}
		assert.Error(err)
		assert.EqualError(err, "Internal Server Error")
	})
	t.Run("should fail when unable to open a file for writing", func(t *testing.T) {
		assert := assert.New(t)
		spec, _ := NewSpec("testdata/spec.yaml")
		err := spec.fetchHTTP(&goodHTTP{}, spec.Sources[0].URL, "/dev/null/test3")
		if err == nil {
			t.Error("expected an error but did not receive one")
		}
		assert.Error(err)
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
		err = spec.fetchHTTP(&goodHTTP{}, spec.Sources[0].URL, tmpfileName)
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
			"b4fc6c456ba6c0405e2197b86ddb8d5cad819dbc5e67991a9cc3da85ae355dab"+
				"b0a3307b5e66970192d925c8abd4e02f0b7c7ac20fe21348d515b413f3ce4fd6")
		assert.Nil(err)
	})
}

type fetchSourceTest struct {
	shouldErr    bool
	preExistFile bool
	preExistMode os.FileMode
	desc         string
	url          string
	blake2       string
	sourceCache  string
	localName    string
	errMsg       string
	client       getter
}

func setupFetchSource(t *testing.T, tt fetchSourceTest, filePath string) (func(t *testing.T), *Spec) {
	spec, _ := NewSpec("testdata/spec.yaml")
	spec.SourceCache = tt.sourceCache
	spec.HTTPClient = tt.client
	if tt.preExistFile {
		if err := os.MkdirAll(spec.SourceCache, 0755); err != nil {
			return func(*testing.T) {
				t.Error(err)
			}, spec
		}
		if err := ioutil.WriteFile(filePath, []byte("Blah blah blah"), tt.preExistMode); err != nil {
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

func TestFetchSource(t *testing.T) {
	var fetchSourceTests = []fetchSourceTest{
		{
			true,
			false,
			0644,
			"should error if URL is unparseable",
			"://blergh",
			"",
			"testdata/src",
			"",
			"parse ://blergh: missing protocol scheme",
			&goodHTTP{},
		},
		{
			true,
			false,
			0644,
			"should error if URL has no scheme",
			"blergh",
			"",
			"testdata/src",
			"",
			"missing protocol scheme",
			&goodHTTP{},
		},
		{
			true,
			false,
			0644,
			"should error if URL.Scheme is unsupported",
			"gxp://blergh/blargh",
			"",
			"testdata/src",
			"",
			"unsupported protocol scheme: gxp",
			&goodHTTP{},
		},
		{
			true,
			false,
			0644,
			"if there is no path provided it should error",
			"https://blergh",
			"",
			"testdata/src",
			"",
			"no path element detected",
			&goodHTTP{},
		},
		{
			true,
			true,
			0644,
			"if file exists but has the wrong sum it should error",
			"https://blergh/blargh",
			"not_a_valid_blake2_sum",
			"testdata/src",
			"blargh",
			"blake2 sum mismatch",
			&goodHTTP{},
		},
		{
			true,
			false,
			0644,
			"http errors should cause it to fail",
			"https://blergh/blargh",
			"d6c9a3102ee1fe35f542bdf8690462e47271fa6339b0682219b864a95a0d8fef7f3f" +
				"3b190758ec3a92cf8a643ab9cdbd6166ec9a5d765d3f0de06cee5979c926",
			"testdata/src",
			"blargh",
			"transit error",
			&badHTTP{},
		},
		{
			true,
			false,
			0644,
			"after successful download, should check blake2 sum again",
			"https://blergh/blargh",
			"not_a_valid_blake2_sum",
			"testdata/src",
			"blargh",
			"blake2 sum mismatch",
			&goodHTTP{},
		},
		{
			false,
			false,
			0644,
			"after successful download, should check blake2 sum again, but succeed",
			"https://blergh/blargh",
			"c3f4db476d1b1504092b4b3756e9b5ef1d658f609e55361e77de6b74d9d77a28" +
				"be46411fd3ce158048c77714925207e47960f3dc0f399f1b8dcbb7e70333dc66",
			"testdata/src",
			"blargh",
			"",
			&goodHTTP{},
		},
		{
			true,
			false,
			0644,
			"if the source cache directory cannot be created it should error",
			"https://blergh/blargh",
			"c3f4db476d1b1504092b4b3756e9b5ef1d658f609e55361e77de6b74d9d77a28" +
				"be46411fd3ce158048c77714925207e47960f3dc0f399f1b8dcbb7e70333dc66",
			"/etc/resolv.conf/src",
			"blargh",
			"/etc/resolv.conf/src: not a directory",
			&goodHTTP{},
		},
	}
	for _, tt := range fetchSourceTests {
		tt := tt
		t.Run(tt.desc, func(t *testing.T) {
			assert := assert.New(t)
			filePath := strings.Join([]string{tt.sourceCache, tt.localName}, "/")
			tearDown, spec := setupFetchSource(t, tt, filePath)
			defer tearDown(t)
			source := Source{tt.url, tt.blake2, tt.localName}
			err := spec.FetchSource(&source)
			if tt.shouldErr {
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
		spec.HTTPClient = &goodHTTP{}
		spec.Sources = []Source{
			{
				"://blergh",
				"not_a_valid_blake2_sum",
				"blergh",
			},
			{
				"https://blargh/blergh",
				"",
				"blergh",
			},
		}
		errors := spec.FetchSources()
		assert.Len(errors, 2)
	})
}
