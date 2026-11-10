package main

import (
	"crypto/subtle"
	"encoding/json"
	"fmt"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"syscall"

	"go.mau.fi/whatsmeow"
)

type downloadRequest struct {
	MessageID string `json:"message_id"`
	ChatJID   string `json:"chat_jid"`
}

type downloadResponse struct {
	Success  bool   `json:"success"`
	Message  string `json:"message"`
	Filename string `json:"filename,omitempty"`
	Path     string `json:"path,omitempty"`
}

const maxMediaBytes = 100 << 20

// MediaDownloader implements whatsmeow.DownloadableMessage for rows already stored.
type MediaDownloader struct {
	DirectPath    string
	MediaKey      []byte
	FileLength    uint64
	FileSHA256    []byte
	FileEncSHA256 []byte
	MediaType     whatsmeow.MediaType
}

func (d *MediaDownloader) GetDirectPath() string             { return d.DirectPath }
func (d *MediaDownloader) GetMediaKey() []byte               { return d.MediaKey }
func (d *MediaDownloader) GetFileLength() uint64             { return d.FileLength }
func (d *MediaDownloader) GetFileSHA256() []byte             { return d.FileSHA256 }
func (d *MediaDownloader) GetFileEncSHA256() []byte          { return d.FileEncSHA256 }
func (d *MediaDownloader) GetMediaType() whatsmeow.MediaType { return d.MediaType }

func newDownloadMux(client BridgeClient, store *MessageStore, mediaDir, token string) http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("/api/download", func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodPost {
			http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
			return
		}
		if !authorized(r, token) {
			http.Error(w, "unauthorized", http.StatusUnauthorized)
			return
		}
		r.Body = http.MaxBytesReader(w, r.Body, 1<<20)
		var req downloadRequest
		if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
			http.Error(w, "invalid request", http.StatusBadRequest)
			return
		}
		if req.MessageID == "" || req.ChatJID == "" {
			http.Error(w, "message id and chat jid are required", http.StatusBadRequest)
			return
		}
		ok, mediaType, filename, path, err := downloadMedia(client, store, mediaDir, req.MessageID, req.ChatJID)
		w.Header().Set("Content-Type", "application/json")
		if !ok || err != nil {
			w.WriteHeader(http.StatusInternalServerError)
			_ = json.NewEncoder(w).Encode(downloadResponse{Success: false, Message: "download failed"})
			return
		}
		_ = json.NewEncoder(w).Encode(downloadResponse{
			Success:  true,
			Message:  "downloaded " + mediaType,
			Filename: filename,
			Path:     path,
		})
	})
	return mux
}

func authorized(r *http.Request, token string) bool {
	got := strings.TrimPrefix(r.Header.Get("Authorization"), "Bearer ")
	if got == r.Header.Get("Authorization") {
		return false
	}
	if len(got) != len(token) || token == "" {
		return false
	}
	return subtle.ConstantTimeCompare([]byte(got), []byte(token)) == 1
}

func downloadMedia(client BridgeClient, store *MessageStore, mediaDir, messageID, chatJID string) (bool, string, string, string, error) {
	mediaType, filename, url, mediaKey, fileSHA256, fileEncSHA256, fileLength, err := store.GetMediaInfo(messageID, chatJID)
	if err != nil {
		return false, "", "", "", err
	}
	if mediaType == "" {
		return false, "", "", "", fmt.Errorf("not a media message")
	}
	localPath, err := mediaPath(mediaDir, chatJID, filename)
	if err != nil {
		return false, "", "", "", err
	}
	if err := os.MkdirAll(filepath.Dir(localPath), 0700); err != nil {
		return false, "", "", "", err
	}
	if info, err := os.Lstat(localPath); err == nil {
		if info.Mode()&os.ModeSymlink != 0 || !info.Mode().IsRegular() {
			return false, "", "", "", fmt.Errorf("media path is not a regular file")
		}
		return true, mediaType, filename, localPath, nil
	}
	if url == "" || len(mediaKey) == 0 || len(fileSHA256) == 0 || len(fileEncSHA256) == 0 || fileLength == 0 {
		return false, "", "", "", fmt.Errorf("incomplete media information")
	}
	if fileLength > maxMediaBytes {
		return false, "", "", "", fmt.Errorf("media exceeds size cap")
	}
	directPath := extractDirectPathFromURL(url)
	if !strings.HasPrefix(directPath, "/") || strings.Contains(directPath, "://") || strings.Contains(directPath, "..") {
		return false, "", "", "", fmt.Errorf("media path rejected")
	}
	if client == nil || !client.IsConnected() {
		return false, "", "", "", fmt.Errorf("not connected")
	}
	var waType whatsmeow.MediaType
	switch mediaType {
	case "image":
		waType = whatsmeow.MediaImage
	case "video":
		waType = whatsmeow.MediaVideo
	case "audio":
		waType = whatsmeow.MediaAudio
	case "document":
		waType = whatsmeow.MediaDocument
	default:
		return false, "", "", "", fmt.Errorf("unsupported media type")
	}
	data, err := client.Download(&MediaDownloader{
		DirectPath:    directPath,
		MediaKey:      mediaKey,
		FileLength:    fileLength,
		FileSHA256:    fileSHA256,
		FileEncSHA256: fileEncSHA256,
		MediaType:     waType,
	})
	if err != nil {
		return false, "", "", "", err
	}
	f, err := os.OpenFile(localPath, os.O_WRONLY|os.O_CREATE|os.O_EXCL|syscall.O_NOFOLLOW, 0600)
	if err != nil {
		return false, "", "", "", err
	}
	defer f.Close()
	if _, err := f.Write(data); err != nil {
		return false, "", "", "", err
	}
	return true, mediaType, filename, localPath, nil
}
