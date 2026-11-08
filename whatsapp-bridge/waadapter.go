package main

import (
	"context"
	"database/sql"
	"fmt"
	"os"

	"go.mau.fi/whatsmeow"
	"go.mau.fi/whatsmeow/store/sqlstore"
	"go.mau.fi/whatsmeow/types"
	waLog "go.mau.fi/whatsmeow/util/log"
)

// Adapter is the only type that holds a whatsmeow client.
// Its methods are the BridgeClient allowlist. Protocol acknowledgements that
// the library emits inside Connect or Download are not user messages and are
// not represented here. MarkRead and available presence are not called.
type Adapter struct {
	client *whatsmeow.Client
}

// NewAdapter opens the session database and builds a client. It does not connect.
func NewAdapter(cfg Config) (*Adapter, error) {
	path := cfg.SessionDB()
	if err := cfg.contain(path); err != nil {
		return nil, err
	}
	dsn, err := sqliteDSN(path)
	if err != nil {
		return nil, err
	}
	container, err := sqlstore.New("sqlite3", dsn, waLog.Noop)
	if err != nil {
		return nil, fmt.Errorf("open session database: %w", err)
	}
	device, err := container.GetFirstDevice()
	if err == sql.ErrNoRows {
		device = container.NewDevice()
	} else if err != nil {
		return nil, fmt.Errorf("read session device: %w", err)
	}
	client := whatsmeow.NewClient(device, waLog.Noop)
	if client == nil {
		return nil, fmt.Errorf("session client was not created")
	}
	// Reconnect an already stored session after a network drop.
	// The library skips this when no device id exists, so it cannot pair by itself.
	client.EnableAutoReconnect = true
	if err := os.Chmod(path, 0600); err != nil {
		return nil, err
	}
	return &Adapter{client: client}, nil
}

func (a *Adapter) DeviceID() string {
	if a == nil || a.client == nil || a.client.Store == nil || a.client.Store.ID == nil {
		return ""
	}
	return a.client.Store.ID.String()
}

func (a *Adapter) OwnUser() string {
	if a == nil || a.client == nil || a.client.Store == nil || a.client.Store.ID == nil {
		return ""
	}
	return a.client.Store.ID.User
}

func (a *Adapter) AddEventHandler(handler func(interface{})) uint32 {
	return a.client.AddEventHandler(handler)
}

func (a *Adapter) Connect() error { return a.client.Connect() }

func (a *Adapter) Disconnect() {
	if a != nil && a.client != nil {
		a.client.Disconnect()
	}
}

func (a *Adapter) IsConnected() bool {
	return a != nil && a.client != nil && a.client.IsConnected()
}

func (a *Adapter) Download(msg whatsmeow.DownloadableMessage) ([]byte, error) {
	return a.client.Download(msg)
}

func (a *Adapter) GroupName(jid types.JID) (string, error) {
	info, err := a.client.GetGroupInfo(jid)
	if err != nil || info == nil {
		return "", err
	}
	return info.Name, nil
}

func (a *Adapter) ContactName(jid types.JID) string {
	if a.client == nil || a.client.Store == nil || a.client.Store.Contacts == nil {
		return ""
	}
	contact, err := a.client.Store.Contacts.GetContact(jid)
	if err != nil {
		return ""
	}
	return contact.FullName
}

func (a *Adapter) PairEvents(ctx context.Context) (<-chan PairEvent, error) {
	ch, err := a.client.GetQRChannel(ctx)
	if err != nil {
		return nil, err
	}
	out := make(chan PairEvent)
	go func() {
		defer close(out)
		for evt := range ch {
			out <- PairEvent{Event: evt.Event, Code: evt.Code}
		}
	}()
	return out, nil
}
