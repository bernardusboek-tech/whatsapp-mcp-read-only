package main

import (
	"fmt"
	"net"
	"net/http"
	"os"
	"time"
)

func listenUnix(path string, handler http.Handler) (net.Listener, *http.Server, error) {
	if info, err := os.Lstat(path); err == nil {
		if info.Mode()&os.ModeSymlink != 0 {
			return nil, nil, fmt.Errorf("socket path is a symlink")
		}
		if info.Mode()&os.ModeSocket == 0 {
			return nil, nil, fmt.Errorf("socket path exists and is not a socket")
		}
		if err := os.Remove(path); err != nil {
			return nil, nil, err
		}
	} else if !os.IsNotExist(err) {
		return nil, nil, err
	}
	ln, err := net.Listen("unix", path)
	if err != nil {
		return nil, nil, err
	}
	if err := os.Chmod(path, 0600); err != nil {
		ln.Close()
		return nil, nil, err
	}
	srv := &http.Server{Handler: handler, ReadHeaderTimeout: 5 * time.Second}
	go func() {
		err := srv.Serve(ln)
		if err != nil && err != http.ErrServerClosed {
			fmt.Fprintf(os.Stderr, "local download listener stopped\n")
		}
	}()
	return ln, srv, nil
}
