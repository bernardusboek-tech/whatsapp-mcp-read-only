package main

import (
	"context"
	"image"
	_ "image/png"
	"net"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/makiuchi-d/gozxing"
	qrdecode "github.com/makiuchi-d/gozxing/qrcode"
	"go.mau.fi/whatsmeow"
	waCommon "go.mau.fi/whatsmeow/proto/waCommon"
	waE2E "go.mau.fi/whatsmeow/proto/waE2E"
	waHist "go.mau.fi/whatsmeow/proto/waHistorySync"
	waWeb "go.mau.fi/whatsmeow/proto/waWeb"
	"go.mau.fi/whatsmeow/types"
	"go.mau.fi/whatsmeow/types/events"
	"google.golang.org/protobuf/proto"
)

type fakeClient struct {
	id          string
	user        string
	connects    int
	disconnects int
	downloads   int
	connected   bool
	pair        func() (<-chan PairEvent, error)
}

func (f *fakeClient) DeviceID() string                         { return f.id }
func (f *fakeClient) OwnUser() string                          { return f.user }
func (f *fakeClient) AddEventHandler(func(interface{})) uint32 { return 1 }
func (f *fakeClient) Connect() error {
	f.connects++
	f.connected = true
	return nil
}
func (f *fakeClient) Disconnect() {
	f.disconnects++
	f.connected = false
}
func (f *fakeClient) IsConnected() bool { return f.connected }
func (f *fakeClient) Download(whatsmeow.DownloadableMessage) ([]byte, error) {
	f.downloads++
	return []byte("synthetic-media-bytes"), nil
}
func (f *fakeClient) GroupName(types.JID) (string, error) { return "Synthetic Group", nil }
func (f *fakeClient) ContactName(types.JID) string        { return "Synthetic Contact" }
func (f *fakeClient) PairEvents(context.Context) (<-chan PairEvent, error) {
	if f.pair == nil {
		return nil, os.ErrInvalid
	}
	return f.pair()
}

func TestConfigRejectsRelativeAndOverlap(t *testing.T) {
	if _, err := LoadConfig("relative/instance", "", "", false); err == nil {
		t.Fatal("relative instance directory was accepted")
	}
	if _, err := LoadConfig("", "", "", false); err == nil {
		t.Fatal("empty instance directory was accepted")
	}
	repo := t.TempDir()
	inside := filepath.Join(repo, "nested")
	if _, err := LoadConfig(inside, "", repo, false); err == nil {
		t.Fatal("instance inside repository was accepted")
	}
	if _, err := os.Stat(inside); !os.IsNotExist(err) {
		t.Fatal("rejected path was created")
	}
	denied := t.TempDir()
	if _, err := LoadConfig(denied, denied, "", false); err == nil {
		t.Fatal("denied instance directory was accepted")
	}
	okDir := t.TempDir()
	instance := filepath.Join(okDir, "instance-a")
	cfg, err := LoadConfig(instance, denied, repo, false)
	if err != nil {
		t.Fatal(err)
	}
	info, err := os.Stat(cfg.InstanceDir)
	if err != nil {
		t.Fatal(err)
	}
	if info.Mode().Perm() != 0700 {
		t.Fatalf("instance mode = %o", info.Mode().Perm())
	}
}

func TestStoresAreSeparate(t *testing.T) {
	left := openTempStore(t)
	right := openTempStore(t)
	body := "synthetic-fixture-alpha"
	if err := left.StoreChat("15550001111@s.whatsapp.net", "Synthetic Contact", time.Unix(1700000000, 0)); err != nil {
		t.Fatal(err)
	}
	if err := left.StoreMessage("m1", "15550001111@s.whatsapp.net", "15550001111", body, time.Unix(1700000000, 0), false, "", "", "", nil, nil, nil, 0); err != nil {
		t.Fatal(err)
	}
	got, err := right.GetMessages("15550001111@s.whatsapp.net", 10)
	if err != nil {
		t.Fatal(err)
	}
	if len(got) != 0 {
		t.Fatalf("second store saw %d rows", len(got))
	}
	info, err := os.Stat(leftPath(t, left))
	if err != nil {
		t.Fatal(err)
	}
	if info.Mode().Perm() != 0600 {
		t.Fatalf("database mode = %o", info.Mode().Perm())
	}
}

func openTempStore(t *testing.T) *MessageStore {
	t.Helper()
	store, err := OpenMessageStore(filepath.Join(t.TempDir(), "messages.db"))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { store.Close() })
	return store
}

func leftPath(t *testing.T, store *MessageStore) string {
	t.Helper()
	var name string
	if err := store.db.QueryRow("PRAGMA database_list").Scan(new(int), new(string), &name); err != nil {
		t.Fatal(err)
	}
	return name
}

func TestMediaPathCannotEscape(t *testing.T) {
	root := filepath.Join(t.TempDir(), "media")
	if err := os.MkdirAll(root, 0700); err != nil {
		t.Fatal(err)
	}
	got, err := mediaPath(root, "15550001111@s.whatsapp.net", "../../escape.txt")
	if err != nil {
		t.Fatal(err)
	}
	rel, err := filepath.Rel(root, got)
	if err != nil || strings.HasPrefix(rel, "..") {
		t.Fatalf("escaped path %s", got)
	}
	if strings.Contains(got, "escape.txt") {
		t.Fatalf("dangerous name preserved: %s", got)
	}
}

func TestHistoryStoresSyntheticTextWithoutLoggingIt(t *testing.T) {
	store := openTempStore(t)
	log := &textLogger{}
	body := "synthetic-history-bravo"
	jid := "15550002222@s.whatsapp.net"
	client := &fakeClient{user: "15550009999"}
	n, err := handleHistorySync(client, store, &events.HistorySync{
		Data: &waHist.HistorySync{
			Conversations: []*waHist.Conversation{{
				ID:   proto.String(jid),
				Name: proto.String("Synthetic History"),
				Messages: []*waHist.HistorySyncMsg{{
					Message: &waWeb.WebMessageInfo{
						Key: &waCommon.MessageKey{
							RemoteJID: proto.String(jid),
							FromMe:    proto.Bool(false),
							ID:        proto.String("H1"),
						},
						Message:          &waE2E.Message{Conversation: proto.String(body)},
						MessageTimestamp: proto.Uint64(1700000000),
					},
				}},
			}},
		},
	}, log)
	if err != nil {
		t.Fatal(err)
	}
	if n != 1 {
		t.Fatalf("stored %d", n)
	}
	rows, err := store.GetMessages(jid, 5)
	if err != nil {
		t.Fatal(err)
	}
	if len(rows) != 1 || rows[0].Content != body {
		t.Fatalf("rows = %#v", rows)
	}
	if strings.Contains(log.text(), body) || strings.Contains(log.text(), jid) {
		t.Fatalf("log leaked private fixture: %s", log.text())
	}
}

func TestRefusesConnectWithoutStoredSession(t *testing.T) {
	dir := filepath.Join(t.TempDir(), "instance")
	cfg, err := LoadConfig(dir, "", "", false)
	if err != nil {
		t.Fatal(err)
	}
	fake := &fakeClient{}
	log := &textLogger{}
	if _, err := Start(cfg, fake, log); err == nil {
		t.Fatal("start connected without a session")
	}
	if fake.connects != 0 {
		t.Fatalf("Connect calls = %d", fake.connects)
	}
}

func TestPairingPayloadIsNotLogged(t *testing.T) {
	dir := filepath.Join(t.TempDir(), "instance")
	cfg, err := LoadConfig(dir, "", "", true)
	if err != nil {
		t.Fatal(err)
	}
	secret := "fixture-pairing-payload-not-a-session"
	fake := &fakeClient{pair: func() (<-chan PairEvent, error) {
		ch := make(chan PairEvent, 2)
		ch <- PairEvent{Event: "code", Code: secret}
		ch <- PairEvent{Event: "success"}
		close(ch)
		return ch, nil
	}}
	log := &textLogger{}
	running, err := Start(cfg, fake, log)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(running.Stop)
	if fake.connects != 1 {
		t.Fatalf("Connect calls = %d", fake.connects)
	}
	payload, err := os.ReadFile(cfg.PairingPath())
	if err != nil {
		t.Fatal(err)
	}
	if string(payload) != secret+"\n" {
		t.Fatal("pairing file missing fixture")
	}
	info, err := os.Stat(cfg.PairingPath())
	if err != nil {
		t.Fatal(err)
	}
	if info.Mode().Perm() != 0600 {
		t.Fatalf("pairing file mode = %o", info.Mode().Perm())
	}
	qrInfo, err := os.Stat(cfg.PairingQRPath())
	if err != nil {
		t.Fatal(err)
	}
	if qrInfo.Mode().Perm() != 0600 {
		t.Fatalf("pairing qr mode = %o", qrInfo.Mode().Perm())
	}
	qrFile, err := os.Open(cfg.PairingQRPath())
	if err != nil {
		t.Fatal(err)
	}
	defer qrFile.Close()
	img, _, err := image.Decode(qrFile)
	if err != nil {
		t.Fatal(err)
	}
	bitmap, err := gozxing.NewBinaryBitmapFromImage(img)
	if err != nil {
		t.Fatal(err)
	}
	decoded, err := qrdecode.NewQRCodeReader().Decode(bitmap, nil)
	if err != nil {
		t.Fatal(err)
	}
	if decoded.GetText() != secret {
		t.Fatal("pairing qr did not decode to the fixture")
	}
	if strings.Contains(log.text(), secret) {
		t.Fatalf("log contained pairing payload: %s", log.text())
	}
}

func TestSendRouteIsAbsentAndDownloadStaysInside(t *testing.T) {
	dir := filepath.Join(t.TempDir(), "instance")
	cfg, err := LoadConfig(dir, "", "", false)
	if err != nil {
		t.Fatal(err)
	}
	fake := &fakeClient{id: "15550003333:1@s.whatsapp.net", connected: true}
	log := &textLogger{}
	running, err := Start(cfg, fake, log)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(running.Stop)
	if fake.connects != 1 {
		t.Fatalf("Connect calls = %d", fake.connects)
	}
	if conn, err := net.Dial("unix", cfg.SocketPath()); err != nil {
		t.Fatal(err)
	} else {
		conn.Close()
	}
	token, err := os.ReadFile(cfg.TokenPath())
	if err != nil {
		t.Fatal(err)
	}
	bearer := strings.TrimSpace(string(token))
	sendReq := httptest.NewRequest(http.MethodPost, "/api/send", strings.NewReader(`{"recipient":"15550003333","message":"nope"}`))
	sendReq.Header.Set("Authorization", "Bearer "+bearer)
	sendRec := httptest.NewRecorder()
	running.server.Handler.ServeHTTP(sendRec, sendReq)
	if sendRec.Code != http.StatusNotFound {
		t.Fatalf("POST /api/send status = %d", sendRec.Code)
	}
	unauth := httptest.NewRequest(http.MethodPost, "/api/download", strings.NewReader(`{"message_id":"m","chat_jid":"j"}`))
	unauthRec := httptest.NewRecorder()
	running.server.Handler.ServeHTTP(unauthRec, unauth)
	if unauthRec.Code != http.StatusUnauthorized {
		t.Fatalf("unauthenticated download status = %d", unauthRec.Code)
	}
	chat := "15550003333@s.whatsapp.net"
	if err := running.store.StoreChat(chat, "Synthetic", time.Unix(1700000000, 0)); err != nil {
		t.Fatal(err)
	}
	if err := running.store.StoreMessage("med1", chat, "15550003333", "", time.Unix(1700000000, 0), false, "document", "../../escape.txt", "https://example.test/file.enc", []byte("key-bytes"), []byte("sha-bytes"), []byte("enc-bytes"), 4); err != nil {
		t.Fatal(err)
	}
	body := `{"message_id":"med1","chat_jid":"` + chat + `"}`
	dl := httptest.NewRequest(http.MethodPost, "/api/download", strings.NewReader(body))
	dl.Header.Set("Authorization", "Bearer "+bearer)
	dlRec := httptest.NewRecorder()
	running.server.Handler.ServeHTTP(dlRec, dl)
	if dlRec.Code != http.StatusOK {
		t.Fatalf("download status = %d body %s", dlRec.Code, dlRec.Body.String())
	}
	if fake.downloads != 1 {
		t.Fatalf("downloads = %d", fake.downloads)
	}
	var escaped []string
	filepath.Walk(filepath.Dir(cfg.InstanceDir), func(path string, info os.FileInfo, err error) error {
		if err == nil && info.Name() == "escape.txt" {
			escaped = append(escaped, path)
		}
		return nil
	})
	if len(escaped) != 0 {
		t.Fatalf("escaped files: %v", escaped)
	}
	if strings.Contains(log.text(), "escape.txt") || strings.Contains(log.text(), bearer) {
		t.Fatalf("log leaked download detail: %s", log.text())
	}
}
