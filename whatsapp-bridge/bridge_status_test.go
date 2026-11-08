package main

import (
	"errors"
	"strings"
	"testing"
)

func TestBridgeFailureLineStaysClassOnly(t *testing.T) {
	line := bridgeFailureLine(errors.New("connect failed: dial tcp: lookup web.whatsapp.com: network is unreachable"))
	if line != "bridge_not_started class=connect_failed" {
		t.Fatal(line)
	}
	for _, banned := range []string{"token", "bearer", "secret", "payload", "session", "qr", "key", "ref="} {
		if strings.Contains(strings.ToLower(line), banned) {
			t.Fatalf("class line contains %s", banned)
		}
	}
	if bridgeFailureClass(errors.New("no stored session; refusing to connect without WA_PAIR=1")) != "pair_disabled" {
		t.Fatal("pair disabled class")
	}
	if bridgeFailureClass(errors.New("pairing timed out")) != "pairing_timeout" {
		t.Fatal("timeout class")
	}
}

func TestBridgeFailureDetailRedactsSecrets(t *testing.T) {
	raw := "connect failed: session rejected token " + strings.Repeat("A", 40) + " qr payload"
	detail := bridgeFailureDetail(errors.New(raw))
	lower := strings.ToLower(detail)
	for _, banned := range []string{"session", "token", "payload", "qr"} {
		if strings.Contains(lower, banned) {
			t.Fatalf("detail still contains %s: %s", banned, detail)
		}
	}
	if strings.Contains(detail, strings.Repeat("A", 32)) {
		t.Fatal("long token was kept")
	}
	if !strings.Contains(detail, "connect failed") {
		t.Fatal(detail)
	}
}
