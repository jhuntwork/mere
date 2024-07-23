package mere

import (
	"context"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"os"

	"github.com/codeclysm/extract/v3"
	"github.com/zeebo/blake3"
)

const (
	defaultDirPerms = 0o755
	fileHeaderBytes = 262
)

var errNotADir = errors.New("not a directory")

type mkdirall func(string, os.FileMode) error

func ensureDir(md mkdirall, path string) error {
	finfo, err := os.Stat(path)
	if err != nil {
		if os.IsNotExist(err) {
			return md(path, defaultDirPerms)
		}
		return fmt.Errorf("%w", err)
	}
	if !finfo.IsDir() {
		return fmt.Errorf("%w: %s", errNotADir, path)
	}
	return nil
}

func computeB3Sum(f io.Reader) (string, error) {
	var buf []byte
	hash := blake3.New()
	if _, err := io.Copy(hash, f); err != nil {
		return "", fmt.Errorf("%w", err)
	}
	sum := hash.Sum(buf)
	return hex.EncodeToString(sum), nil
}

func computeB3SumFromFile(filename string) (string, error) {
	f, err := os.Open(filename)
	if err != nil {
		return "", fmt.Errorf("%w", err)
	}
	defer f.Close()
	return computeB3Sum(f)
}

func (source *Source) checkB3SumFromFile(filename string, b3sum string) error {
	fmt.Fprintf(source.output, "Validating %s\n", filename)
	sum, err := computeB3SumFromFile(filename)
	if err != nil {
		return err
	}
	if sum != b3sum {
		return fmt.Errorf("%w:\n\texpected: %s\n\tactual:   %s", errHash, b3sum, sum)
	}
	return nil
}

// Given a filename and directory, treat filename as an archive and extract its contents to the directory.
func extractArchive(filepath string, dir string) error {
	f, err := os.Open(filepath)
	if err != nil {
		return fmt.Errorf("%w", err)
	}
	defer f.Close()
	err = extract.Archive(context.Background(), f, dir, nil)
	if err != nil {
		return fmt.Errorf("%w", err)
	}
	return nil
}
