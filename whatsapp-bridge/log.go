package main

import "fmt"

// Logger receives operational state only. Callers must not pass message
// bodies, media keys, tokens, or pairing payloads.
type Logger interface {
	Infof(format string, args ...interface{})
	Errorf(format string, args ...interface{})
}

type stdoutLogger struct{}

func (stdoutLogger) Infof(format string, args ...interface{}) {
	fmt.Printf(format+"\n", args...)
}

func (stdoutLogger) Errorf(format string, args ...interface{}) {
	fmt.Printf("error: "+format+"\n", args...)
}

// textLogger keeps log lines for tests.
type textLogger struct {
	lines []string
}

func (l *textLogger) Infof(format string, args ...interface{}) {
	l.lines = append(l.lines, fmt.Sprintf(format, args...))
}

func (l *textLogger) Errorf(format string, args ...interface{}) {
	l.lines = append(l.lines, fmt.Sprintf("error: "+format, args...))
}

func (l *textLogger) text() string {
	out := ""
	for _, line := range l.lines {
		out += line + "\n"
	}
	return out
}
