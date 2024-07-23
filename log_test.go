package mere_test

import (
	"bytes"
	"testing"

	"github.com/jhuntwork/mere"
	"github.com/stretchr/testify/assert"
)

const msg = "test message"

func TestLogInfo(t *testing.T) {
	t.Parallel()
	t.Run("Should output message with a newline", func(t *testing.T) {
		t.Parallel()
		assert := assert.New(t)
		var buf bytes.Buffer
		log := mere.Log{Output: &buf}
		log.Info(msg)
		assert.Equal(msg+"\n", buf.String())
	})
}

func TestDebugInfo(t *testing.T) {
	t.Parallel()
	t.Run("Should not output message if debug is not enabled", func(t *testing.T) {
		t.Parallel()
		assert := assert.New(t)
		var buf bytes.Buffer
		log := mere.Log{Output: &buf}
		log.Debug(msg)
		assert.Equal("", buf.String())
	})
	t.Run("Should output message if debug is enabled", func(t *testing.T) {
		t.Parallel()
		assert := assert.New(t)
		var buf bytes.Buffer
		log := mere.Log{Output: &buf, EnableDebug: true}
		log.Debug(msg)
		assert.Equal(msg+"\n", buf.String())
	})
}
