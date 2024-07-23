package mere

import (
	"bytes"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

/*
  The default length of 60 lines seems generally reasonable. But in this case, the concise
  nature of table driven unit tests alongside the goal of more complete coverage outweigh
  the goal of short function length.
*/

const goodBody = "content"

var (
	errRead    = errors.New("this is a mock Read failure")
	errClose   = errors.New("this is a mock Close failure")
	errTransit = errors.New("transit error")
)

type (
	badCopier       struct{}
	badReader       struct{}
	mockCopier      struct{}
	badHTTP         struct{}
	serverErrHTTP   struct{}
	goodHTTP        struct{}
	goodHTTPBadBody struct{}
)

func (badCopier) Copy(_ io.Writer, _ io.Reader) (int64, error) {
	return 0, fmt.Errorf("%w", errRead)
}

func (mockCopier) Copy(io.Writer, io.Reader) (int64, error) {
	return 0, nil
}

func (s *serverErrHTTP) Do(*http.Request) (*http.Response, error) {
	var resp http.Response
	resp.StatusCode = 500
	resp.Body = io.NopCloser(bytes.NewBufferString(""))
	return &resp, nil
}

func (b *badHTTP) Do(*http.Request) (*http.Response, error) {
	var resp http.Response
	return &resp, fmt.Errorf("%w", errTransit)
}

func (g *goodHTTP) Do(*http.Request) (*http.Response, error) {
	var resp http.Response
	resp.StatusCode = 200
	resp.Body = io.NopCloser(bytes.NewBufferString(goodBody))
	resp.ContentLength = int64(len(goodBody))
	return &resp, nil
}

func (*badReader) Read([]byte) (int, error) {
	return 0, fmt.Errorf("%w", errRead)
}

func (*badReader) Close() error {
	return fmt.Errorf("%w", errClose)
}

func (g *goodHTTPBadBody) Do(*http.Request) (*http.Response, error) {
	var resp http.Response
	resp.StatusCode = 200
	resp.Body = &badReader{}

	return &resp, nil
}

func Test_fetchFile(t *testing.T) {
	tests := []struct {
		description string
		src         string
		dest        string
		errMsg      string
		copier      copier
	}{
		{
			description: "Should fail if unable to open the source file",
			src:         "/dev/null/no-such-file",
			dest:        "/dev/null",
			errMsg:      "open /dev/null/no-such-file: not a directory",
			copier:      mockCopier{},
		},
		{
			description: "Should fail if unable to open the destination file",
			src:         "/dev/null",
			dest:        "/dev/null/no-such-file",
			errMsg:      "open /dev/null/no-such-file: not a directory",
			copier:      mockCopier{},
		},
		{
			description: "Should fail if encountering an error while copying",
			src:         "/dev/null",
			dest:        "/dev/null",
			errMsg:      errRead.Error(),
			copier:      badCopier{},
		},
		{
			description: "Should succeed generally",
			src:         "/dev/null",
			dest:        "/dev/null",
			copier:      mockCopier{},
		},
	}
	t.Parallel()
	for _, test := range tests {
		t.Run(test.description, func(t *testing.T) {
			t.Parallel()
			assert := assert.New(t)
			err := fetchFile(test.copier, test.src, test.dest)
			if test.errMsg == "" {
				require.NoError(t, err)
			} else if assert.Error(err) {
				assert.Equal(test.errMsg, err.Error())
			}
		})
	}
}

//nolint:funlen
func Test_fetchHTTP(t *testing.T) {
	tests := []struct {
		description string
		client      doer
		errMsg      string
		url         string
		dest        string
	}{
		{
			description: "Should fail if there is an http error",
			client:      &badHTTP{},
			errMsg:      "transit error",
			url:         "https://example.com",
		},
		{
			description: "Should fail if there is a server error",
			client:      &serverErrHTTP{},
			errMsg:      "received an HTTP error: 500 Internal Server Error",
			url:         "https://example.com",
		},
		{
			description: "Should succeed generally",
			client:      &goodHTTP{},
			url:         "https://example.com",
		},
		{
			// Using a real http.Client in this test is fine because the URL is invalid
			description: "Should fail when the url is bad",
			client:      &http.Client{},
			errMsg:      `Get "blargh": unsupported protocol scheme ""`,
			url:         "blargh",
		},
		{
			description: "Should fail if the destination is unwritable",
			url:         "https://blergh/blargh",
			errMsg:      "open /dev/null/badpath: not a directory",
			client:      &goodHTTP{},
			dest:        "/dev/null/badpath",
		},
		{
			description: "Should fail if there is a problem during the read",
			url:         "https://blergh/blargh",
			errMsg:      errRead.Error(),
			client:      &goodHTTPBadBody{},
		},
	}
	t.Parallel()
	for _, test := range tests {
		t.Run(test.description, func(t *testing.T) {
			t.Parallel()
			assert := assert.New(t)
			if test.dest == "" {
				test.dest = "/dev/null"
			}
			err := fetchHTTP(test.client, test.url, test.dest)
			if test.errMsg != "" {
				if err == nil {
					t.Error("expected an error but did not receive one")
				}
				if assert.Error(err) {
					assert.EqualError(err, test.errMsg)
				}
			} else {
				require.NoError(t, err)
			}
		})
	}
}

//nolint:funlen
func Test_fetch(t *testing.T) {
	tests := []struct {
		description string
		src         url.URL
		dest        string
		errMsg      string
		client      doer
	}{
		{
			description: "Should detect http and pass through errors from fetchHTTP",
			src: url.URL{
				Scheme: "http",
				Host:   "example.com",
				Path:   "/",
			},
			dest:   "/dev/null",
			errMsg: "transit error",
			client: &badHTTP{},
		},
		{
			description: "Should detect https and pass through errors from fetchHTTP",
			src: url.URL{
				Scheme: "https",
				Host:   "example.com",
				Path:   "/",
			},
			dest:   "/dev/null",
			errMsg: "transit error",
			client: &badHTTP{},
		},
		{
			description: "Should detect a file and pass through errors from fetchFile",
			src: url.URL{
				Scheme: "file",
				Path:   "/dev/null/badpath",
			},
			dest:   "/dev/null",
			errMsg: "open /dev/null/badpath: not a directory",
			client: &badHTTP{},
		},
		{
			description: "Should fail when given a bad destination",
			src: url.URL{
				Scheme: "https",
				Host:   "example.com",
				Path:   "/",
			},
			dest:   "/dev/null/badpath",
			errMsg: "not a directory: /dev/null",
			client: &badHTTP{},
		},
		{
			description: "Should error with an unsupported scheme",
			src: url.URL{
				Scheme: "junk",
				Path:   "/dev/null/badpath",
			},
			dest:   "/dev/null",
			errMsg: "unsupported protocol scheme: junk",
			client: &badHTTP{},
		},
		{
			description: "Should succeed generally",
			src: url.URL{
				Scheme: "http",
				Host:   "example.com",
				Path:   "/",
			},
			dest:   "/dev/null",
			client: &goodHTTP{},
		},
	}
	t.Parallel()
	for _, test := range tests {
		t.Run(test.description, func(t *testing.T) {
			t.Parallel()
			assert := assert.New(t)
			var buf bytes.Buffer
			log := Log{Output: &buf}
			mereObj, _ := NewMere(log, "")
			mereObj.httpclient = test.client
			err := mereObj.fetch(test.src, test.dest)
			if test.errMsg == "" {
				require.NoError(t, err)
			} else if assert.Error(err) {
				assert.Equal(test.errMsg, err.Error())
			}
		})
	}
}
