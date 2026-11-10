package main

import (
	"os"
	"strings"
	"testing"
)

// TestOfflineConnectErrorClass runs the real bridge client with pairing enabled.
// It is skipped unless WA_OFFLINE_CONNECT=1. Run it without outbound network so it
// cannot reach WhatsApp. The assertion is the error class, not a live pairing.
func TestOfflineConnectErrorClass(t *testing.T) {
	if os.Getenv("WA_OFFLINE_CONNECT") != "1" {
		t.Skip("set WA_OFFLINE_CONNECT=1 on a network-isolated runner")
	}
	dir := t.TempDir()
	cfg, err := LoadConfig(dir, "", "", true)
	if err != nil {
		t.Fatal(err)
	}
	adapter, err := NewAdapter(cfg)
	if err != nil {
		t.Fatal(err)
	}
	if adapter.DeviceID() != "" {
		t.Fatal("new store already has a device id")
	}
	connectErr := adapter.Connect()
	log := &textLogger{}
	_, startErr := Start(cfg, adapter, log)
	if startErr == nil {
		t.Fatal("pairing start succeeded without a network")
	}
	if _, err := os.Stat(cfg.PairingQRPath()); !os.IsNotExist(err) {
		t.Fatal("qr image appeared without a completed code event")
	}
	if _, err := os.Stat(cfg.PairingPath()); !os.IsNotExist(err) {
		t.Fatal("pairing payload appeared without a completed code event")
	}
	combined := startErr.Error() + "\n" + log.text()
	if strings.Contains(combined, "pairing payload") || strings.Contains(log.text(), "pairing finished") {
		t.Fatal("pairing was reported complete")
	}
	if bridgeFailureClass(startErr) != "connect_failed" {
		t.Fatalf("class=%s err=%v", bridgeFailureClass(startErr), startErr)
	}
	line := bridgeFailureLine(startErr)
	if line != "bridge_not_started class=connect_failed" {
		t.Fatal(line)
	}
	if connectErr == nil {
		t.Fatal("direct connect succeeded while isolated")
	}
}
