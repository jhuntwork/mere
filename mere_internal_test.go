package mere

import (
	"testing"

	"github.com/stretchr/testify/require"
)

func Test_validateURL(t *testing.T) {
	t.Parallel()
	tests := []struct {
		description string
		url         string
		errMsg      string
	}{
		{
			description: "Should not fail when given a valid URL",
			url:         "https://pkgs.merelinux.org/somefile",
			errMsg:      "",
		},
		{
			description: "Should fail when given an invalid URL",
			url:         "://pkgs.merelinux.org",
			errMsg:      `parse "://pkgs.merelinux.org": missing protocol scheme`,
		},
		{
			description: "Should fail when given an unsupported URL scheme",
			url:         "junk://pkgs.merelinux.org",
			errMsg:      "unsupported protocol scheme: junk",
		},
		{
			description: "Should fail when not given a URL scheme",
			url:         "pkgs.merelinux.org",
			errMsg:      "missing protocol scheme",
		},
	}
	for _, test := range tests {
		t.Run(test.description, func(t *testing.T) {
			t.Parallel()
			_, err := validateURL(test.url)
			if test.errMsg != "" {
				require.Error(t, err)
				require.Equal(t, test.errMsg, err.Error())
			} else {
				require.NoError(t, err)
			}
		})
	}
}
