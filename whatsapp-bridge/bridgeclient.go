package main

import (
	"context"

	"go.mau.fi/whatsmeow"
	"go.mau.fi/whatsmeow/types"
)

// PairEvent is a pairing-channel item. Code is a secret and must be written
// only to the instance pairing file.
type PairEvent struct {
	Event string
	Code  string
}

// BridgeClient is the application-facing session API.
// It intentionally has no method for sending a user message, uploading media,
// marking a chat read, or publishing available presence.
type BridgeClient interface {
	DeviceID() string
	OwnUser() string
	AddEventHandler(func(interface{})) uint32
	Connect() error
	Disconnect()
	IsConnected() bool
	Download(whatsmeow.DownloadableMessage) ([]byte, error)
	GroupName(jid types.JID) (string, error)
	ContactName(jid types.JID) string
	PairEvents(ctx context.Context) (<-chan PairEvent, error)
}
