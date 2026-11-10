package main

import (
	"fmt"
	"os"
	"os/signal"
	"syscall"
)

func main() {
	syscall.Umask(0077)
	cfg, err := LoadConfigFromEnv()
	if err != nil {
		fmt.Fprintf(os.Stderr, "configuration rejected\n")
		os.Exit(2)
	}
	client, err := NewAdapter(cfg)
	if err != nil {
		fmt.Fprintf(os.Stderr, "session storage rejected\n")
		os.Exit(1)
	}
	running, err := Start(cfg, client, stdoutLogger{})
	if err != nil {
		fmt.Fprintf(os.Stderr, "bridge not started\n")
		fmt.Fprintf(os.Stderr, "%s\n", bridgeFailureLine(err))
		fmt.Fprintf(os.Stderr, "%s\n", bridgeFailureDetail(err))
		os.Exit(1)
	}
	if err := writeSecretFile(cfg.PIDPath(), []byte(fmt.Sprintf("%d\n", os.Getpid()))); err != nil {
		running.Stop()
		fmt.Fprintf(os.Stderr, "pid file rejected\n")
		os.Exit(1)
	}
	fmt.Printf("bridge ready\n")
	signals := make(chan os.Signal, 1)
	signal.Notify(signals, syscall.SIGINT, syscall.SIGTERM)
	<-signals
	running.Stop()
	_ = os.Remove(cfg.PIDPath())
}
