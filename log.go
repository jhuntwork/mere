package mere

import (
	"fmt"
	"io"
)

// Logger is an interface that presents only two main logging methods, Info and Debug.
type Logger interface {
	Info(message string)
	Debug(message string)
}

// Log provides an implementation of Logger.
type Log struct {
	EnableDebug bool
	Output      io.Writer
}

func (l Log) Info(msg string) {
	fmt.Fprintln(l.Output, msg)
}

func (l Log) Debug(msg string) {
	if l.EnableDebug {
		fmt.Fprintln(l.Output, msg)
	}
}
