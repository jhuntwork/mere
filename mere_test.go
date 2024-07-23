package mere_test

import (
	"bytes"
	"os"
	"testing"

	"github.com/jhuntwork/mere"
	"github.com/stretchr/testify/require"
)

func TestNewMere(t *testing.T) {
	t.Parallel()
	t.Run("Should fail if the given store does not exist", func(t *testing.T) {
		t.Parallel()
		var buf bytes.Buffer
		log := mere.Log{Output: &buf}
		_, err := mere.NewMere(log, "testdata/non-existent-dir")
		require.ErrorIs(t, err, os.ErrNotExist)
	})
	t.Run("Should fail if the given store is a file", func(t *testing.T) {
		t.Parallel()
		var buf bytes.Buffer
		log := mere.Log{Output: &buf}
		_, err := mere.NewMere(log, "testdata/spec.yaml")
		require.ErrorIs(t, err, mere.ErrStoreIsFile)
	})
	t.Run("Should fail if the given store has incorrect permissions", func(t *testing.T) {
		t.Parallel()
		tmpdir, _ := os.MkdirTemp("", "")
		defer os.RemoveAll(tmpdir)
		dir := tmpdir + "/test"
		err := os.Mkdir(dir, 0o700)
		require.NoError(t, err)
		err = os.Chmod(dir, 0o700) // Explicitly change to desired permissions to bypass possible umask
		require.NoError(t, err)
		var buf bytes.Buffer
		log := mere.Log{Output: &buf}
		_, err = mere.NewMere(log, dir)
		require.ErrorIs(t, err, mere.ErrStoreBadPermissions)
	})
	/*
		t.Run("Should fail if the given store is not owned by the 'mere' group", func(t *testing.T) {
			t.Parallel()
			assert := assert.New(t)
			var buf bytes.Buffer
			log := mere.Log{Output: &buf}
			_, err := mere.NewMere(log, "testdata/spec.yaml")
			assert.ErrorIs(err, mere.ErrStoreBadGroup)
		})
	*/
	t.Run("Should not fail generally", func(t *testing.T) {
		t.Parallel()
		tmpdir, _ := os.MkdirTemp("", "")
		defer os.RemoveAll(tmpdir)
		dir := tmpdir + "/test"
		err := os.Mkdir(dir, 0o700)
		require.NoError(t, err)
		err = os.Chmod(dir, 0o775) // Explicitly change to correct permissions to bypass possible umask
		require.NoError(t, err)
		var buf bytes.Buffer
		log := mere.Log{Output: &buf}
		_, err = mere.NewMere(log, dir)
		require.NoError(t, err)
	})
}
