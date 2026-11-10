package main

import (
	"crypto/rand"
	"encoding/hex"
	"os"
	"syscall"
)

func writeSecretFile(path string, data []byte) error {
	f, err := os.OpenFile(path, os.O_WRONLY|os.O_CREATE|os.O_TRUNC|syscall.O_NOFOLLOW, 0600)
	if err != nil {
		return err
	}
	defer f.Close()
	if _, err := f.Write(data); err != nil {
		return err
	}
	return f.Chmod(0600)
}

func regenerateToken(path string) (string, error) {
	buf := make([]byte, 32)
	if _, err := rand.Read(buf); err != nil {
		return "", err
	}
	token := hex.EncodeToString(buf)
	if err := writeSecretFile(path, []byte(token+"\n")); err != nil {
		return "", err
	}
	return token, nil
}
