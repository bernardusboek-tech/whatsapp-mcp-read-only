package main

import (
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"os"
	"path/filepath"
	"strings"
)

// mediaPath returns a file path inside root. chatJID and filename are reduced
// to a single path segment so a remote filename cannot escape the instance.
func mediaPath(root, chatJID, filename string) (string, error) {
	if !filepath.IsAbs(root) {
		return "", fmt.Errorf("media root must be absolute")
	}
	chat := oneSegment(chatJID)
	file := oneSegment(filename)
	if chat == "" || file == "" {
		return "", fmt.Errorf("media name is empty")
	}
	full := filepath.Join(root, chat, file)
	rel, err := filepath.Rel(filepath.Clean(root), full)
	if err != nil || rel == "." || rel == ".." || strings.HasPrefix(rel, ".."+string(os.PathSeparator)) {
		return "", fmt.Errorf("media path escapes store")
	}
	return full, nil
}

func oneSegment(value string) string {
	value = strings.ReplaceAll(value, ":", "_")
	value = strings.TrimSpace(value)
	if value == "" || value == "." || value == ".." {
		return ""
	}
	if strings.ContainsAny(value, `/\`) || strings.Contains(value, "..") || strings.ContainsRune(value, 0) {
		sum := sha256.Sum256([]byte(value))
		return hex.EncodeToString(sum[:8])
	}
	if len(value) > 80 {
		value = value[:80]
	}
	return value
}
