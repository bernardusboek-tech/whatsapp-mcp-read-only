package main

import (
	"context"
	"fmt"
	"net"
	"net/http"
	"os"
	"time"

	"go.mau.fi/whatsmeow/types/events"
)

// Running is a local bridge. Stop closes the socket and disconnects.
// Disconnect does not unlink a device; that remains a phone-side action.
type Running struct {
	cfg    Config
	client BridgeClient
	store  *MessageStore
	server *http.Server
	ln     net.Listener
	log    Logger
}

// Start prepares local storage and the download socket before any connect.
// With no stored device id and pairing disabled, it returns before Connect.
func Start(cfg Config, client BridgeClient, log Logger) (*Running, error) {
	if log == nil {
		log = stdoutLogger{}
	}
	if client == nil {
		return nil, fmt.Errorf("missing session client")
	}
	if err := os.MkdirAll(cfg.MediaDir(), 0700); err != nil {
		return nil, err
	}
	store, err := OpenMessageStore(cfg.MessagesDB())
	if err != nil {
		return nil, err
	}
	token, err := regenerateToken(cfg.TokenPath())
	if err != nil {
		store.Close()
		return nil, err
	}
	mux := newDownloadMux(client, store, cfg.MediaDir(), token)
	ln, srv, err := listenUnix(cfg.SocketPath(), mux)
	if err != nil {
		store.Close()
		return nil, err
	}
	running := &Running{cfg: cfg, client: client, store: store, server: srv, ln: ln, log: log}
	client.AddEventHandler(func(evt interface{}) {
		switch v := evt.(type) {
		case *events.Message:
			if err := handleMessage(client, store, v, log); err != nil {
				log.Errorf("store message failed")
			}
		case *events.HistorySync:
			n, err := handleHistorySync(client, store, v, log)
			if err != nil {
				log.Errorf("store history failed")
			}
			log.Infof("history sync stored %d messages", n)
		case *events.Connected:
			log.Infof("connected")
		case *events.LoggedOut:
			log.Infof("logged out by the server; local message rows were kept")
		}
	})
	if client.DeviceID() == "" && !cfg.Pair {
		running.closeLocal()
		return nil, fmt.Errorf("no stored session; refusing to connect without WA_PAIR=1")
	}
	if client.DeviceID() == "" {
		if err := running.pair(context.Background()); err != nil {
			running.Stop()
			return nil, err
		}
		log.Infof("pairing session ready")
		return running, nil
	}
	if err := client.Connect(); err != nil {
		client.Disconnect()
		running.closeLocal()
		return nil, fmt.Errorf("connect failed")
	}
	log.Infof("session connect requested")
	return running, nil
}

func (r *Running) pair(ctx context.Context) error {
	eventsCh, err := r.client.PairEvents(ctx)
	if err != nil {
		return err
	}
	if err := r.client.Connect(); err != nil {
		return fmt.Errorf("connect failed")
	}
	timeout := time.After(3 * time.Minute)
	for {
		select {
		case evt, ok := <-eventsCh:
			if !ok {
				return fmt.Errorf("pairing ended before success")
			}
			if evt.Event == "code" && evt.Code != "" {
				if err := writeSecretFile(r.cfg.PairingPath(), []byte(evt.Code+"\n")); err != nil {
					return err
				}
				r.log.Infof("pairing payload written")
			} else if evt.Event == "success" {
				r.log.Infof("pairing finished")
				return nil
			}
		case <-timeout:
			return fmt.Errorf("pairing timed out")
		case <-ctx.Done():
			return ctx.Err()
		}
	}
}

func (r *Running) closeLocal() {
	if r.server != nil {
		_ = r.server.Close()
	}
	if r.ln != nil {
		_ = r.ln.Close()
	}
	if r.cfg.SocketPath() != "" {
		_ = os.Remove(r.cfg.SocketPath())
	}
	if r.store != nil {
		_ = r.store.Close()
		r.store = nil
	}
}

// Stop disconnects the socket session and removes the local listener.
func (r *Running) Stop() {
	if r == nil {
		return
	}
	if r.client != nil {
		r.client.Disconnect()
	}
	r.closeLocal()
	r.log.Infof("stopped")
}
