package mere

import (
	"errors"
	"fmt"
	"testing"

	"github.com/stretchr/testify/assert"
)

type badUnmarshal struct{}

var errUnmarshal = errors.New("failed to Unmarshal")

func (b *badUnmarshal) Marshal(interface{}) ([]byte, error) {
	return []byte{}, nil
}

func (b *badUnmarshal) Unmarshal([]byte, interface{}) error {
	return fmt.Errorf("%w", errUnmarshal)
}

func Test_validateSchema(t *testing.T) {
	t.Parallel()
	t.Run("errors from Unmarshal should fail the validation", func(t *testing.T) {
		t.Parallel()
		assert := assert.New(t)
		spec := Spec{}
		err := spec.validateSchema("testdata/spec.yaml", &badUnmarshal{})
		assert.EqualError(err, "failed to Unmarshal")
	})
}
