package mere

import (
	"errors"
	"fmt"
	"io/ioutil"
	"os"
	"os/exec"
	"path"
	"strings"
)

var errBuild = errors.New("build error")

const (
	build      = "build"
	pkg        = "package"
	src        = "source"
	merePkgdir = "MERE_PKGDIR"
	mereSrcdir = "MERE_SRCDIR"
)

type temper interface {
	tempdir(string, string) (string, error)
}

type tempd struct{}

func (t tempd) tempdir(dir, pattern string) (string, error) {
	return ioutil.TempDir(dir, pattern)
}

type linker interface {
	symlink(string, string) error
}

type slink struct{}

func (s slink) symlink(oldname, newname string) error {
	return os.Symlink(oldname, newname)
}

func (s *Spec) createWorkingDir(t temper) (string, error) {
	var empty string
	pattern := strings.Join([]string{path.Base(s.Name), s.Version, "*"}, "-")
	wd, err := t.tempdir(empty, pattern)
	if err != nil {
		return empty, fmt.Errorf("%w", err)
	}
	for _, dir := range []string{build, pkg, src} {
		if err = ensureDir(os.Mkdir, fmt.Sprintf("%s/%s", wd, dir)); err != nil {
			return empty, fmt.Errorf("%w", err)
		}
	}
	return wd, err
}

func (s *Spec) executeStage(stage string) error {
	cmd := exec.Command("sh", "-c", "set -e\n"+stage) //#nosec
	cmd.Stdout = s.output
	cmd.Stderr = os.Stderr
	cmd.Dir = s.buildContext
	cmd.Env = []string{
		fmt.Sprintf("%s=%s/%s", merePkgdir, s.workingDir, pkg),
		fmt.Sprintf("%s=%s/%s", mereSrcdir, s.workingDir, src),
	}
	err := cmd.Run()
	if err != nil {
		return fmt.Errorf("%w", err)
	}
	return nil
}

func (s *Spec) setupSymlinks(l linker) error {
	for _, source := range s.Sources {
		base := path.Base(source.savePath)
		err := l.symlink(source.savePath, fmt.Sprintf("%s/%s/%s", s.workingDir, src, base))
		if err != nil {
			return fmt.Errorf("%w", err)
		}
	}
	return nil
}

func (s *Spec) buildSteps(t temper, l linker) error {
	errors := s.fetchSources()
	if len(errors) != 0 {
		return fmt.Errorf("%w: %v", errBuild, errors)
	}
	wd, err := s.createWorkingDir(t)
	if err != nil {
		return fmt.Errorf("%w", err)
	}
	s.workingDir = wd
	s.buildContext = fmt.Sprintf("%s/%s", wd, build)

	if len(s.Sources) > 0 {
		if err := s.Sources[0].extract(s.buildContext); err != nil {
			return err
		}

		// s.workingDir is a tempdir, most often it will contain one top level directory
		files, _ := ioutil.ReadDir(s.buildContext)
		if len(files) == 1 {
			checkPath := s.buildContext + "/" + files[0].Name()
			info, _ := os.Stat(checkPath)
			if info.IsDir() {
				s.buildContext = checkPath
			}
		}
	}

	fmt.Fprintf(s.output, "Context directory is %s", s.buildContext)

	err = s.setupSymlinks(l)
	if err != nil {
		return fmt.Errorf("%w", err)
	}

	for _, stage := range s.buildOrder {
		if stage["cmd"] != "" {
			fmt.Fprintf(s.output, "Executing stage %s", stage["name"])
			err = s.executeStage(stage["cmd"])
			if err != nil {
				return fmt.Errorf("%w", err)
			}
		}
	}
	return nil
}

// BuildSteps executes the build, test and install steps as defined in a package spec.
func (s *Spec) BuildSteps() error {
	return s.buildSteps(tempd{}, slink{})
}

// Cleanup removes the entire internal working directory.
func (s *Spec) Cleanup() {
	os.RemoveAll(s.workingDir)
}
