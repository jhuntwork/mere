package mere

import (
	"bytes"
	"fmt"
	"os"
	"strings"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

const (
	// output of goodHTTP.Get function.
	goodHTTPB3Sum = "3fba5250be9ac259c56e7250c526bc83bacb4be825f2799d3d59e5b4878dd74e"
	fileB3Sum     = "b319b03ad4ff94817e3555791bb67df918cd86466fc14426d4a969d94ded5c37"
	sourceCache   = "testdata/src"
)

type sourceTest struct {
	description  string
	preExistFile bool
	url          string
	b3sum        string
	sourceCache  string
	localName    string
	errMsg       string
	client       doer
}

func setupsource(t *testing.T, test sourceTest, filePath string) (func(t *testing.T), *Spec) {
	t.Helper()
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

		if err := os.WriteFile(filePath, []byte("Blah bleh bluh"), 0o600); err != nil {
			return func(*testing.T) {
				t.Error(err)
			}, spec
		}
	}

	return func(t *testing.T) {
		t.Helper()
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
			url:         "testdata/testarchive.tar.gz",
			b3sum:       fileB3Sum,
		},
		{
			description: "test using a bad file path",
			url:         "file:///dev/null/no-such-file",
			errMsg:      "open /dev/null/no-such-file: not a directory",
		},
	}
	for i, tc := range fetchsourceTests {
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
			require.NoError(t, err)
			spec.httpclient = tc.client
			err = source.fetchSource(spec)
			if tc.errMsg != "" {
				if err == nil {
					t.Errorf("expected an error but didn't receive one")
				} else {
					assert.Contains(err.Error(), tc.errMsg)
				}
			} else {
				require.NoError(t, err)
				finfo, err := os.Stat(filePath)
				require.NoError(t, err)
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
			description: "should use fileProto if URL has no scheme",
			url:         "blergh",
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
