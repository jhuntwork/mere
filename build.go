package mere

import (
	"errors"
	"fmt"
	"io/ioutil"
	"os"
	"os/exec"
	"path"
	"strings"

	"github.com/jhuntwork/aia-transport-go"
)

var errBuild = errors.New("build error")

const (
	build      = "build"
	pkg        = "package"
	src        = "source"
	merePkgdir = "MERE_PKGDIR"
	mereSrcdir = "MERE_SRCDIR"
)

func (s *Spec) createWorkingDir() (string, error) {
	pattern := strings.Join([]string{path.Base(s.Name), s.Version, "*"}, "-")
	wd, err := s.tempDirFunc("", pattern)
	if err != nil {
		return "", fmt.Errorf("%w", err)
	}
	for _, dir := range []string{build, pkg, src} {
		if err = ensureDir(os.Mkdir, fmt.Sprintf("%s/%s", wd, dir)); err != nil {
			return "", fmt.Errorf("%w", err)
		}
	}

	return wd, err
}

func (s *Spec) executeStage(stage string) error {
	cmd := exec.Command("sh", "-c", "set -e\n"+stage) //#nosec
	cmd.Stdout = os.Stdout
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

// BuildSteps executes the build, test and install steps as defined in a package spec.
func (s *Spec) BuildSteps() error {
	errors := s.sourcesFunc(s.Sources, s.sourceCache, aia.NewTransport)
	if len(errors) != 0 {
		return fmt.Errorf("%w: %v", errBuild, errors)
	}
	wd, err := s.createWorkingDir()
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

	for _, source := range s.Sources {
		base := path.Base(source.savePath)
		err = s.symlinkFunc(source.savePath, fmt.Sprintf("%s/%s/%s", s.workingDir, src, base))
		if err != nil {
			return fmt.Errorf("%w", err)
		}
	}

	s.printHook(fmt.Sprintf("Context directory is %s", s.buildContext))

	for _, stage := range s.buildOrder {
		if stage["cmd"] != "" {
			s.printHook(fmt.Sprintf("Executing stage %s", stage["name"]))
			err = s.executeStage(stage["cmd"])
			if err != nil {
				return fmt.Errorf("%w", err)
			}
		}
	}

	return nil
}
