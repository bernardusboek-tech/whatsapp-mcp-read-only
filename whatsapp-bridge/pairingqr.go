package main

import (
	"fmt"
	"strings"

	"github.com/skip2/go-qrcode"
)

// writePairingQR renders the pairing text as a scannable image.
// The text stays in the image file. It is not written to the log.
func writePairingQR(path, code string) error {
	code = strings.TrimRight(code, "\n")
	if code == "" || strings.ContainsAny(code, "\r\n") {
		return fmt.Errorf("pairing code is empty")
	}
	png, err := qrcode.Encode(code, qrcode.Medium, 320)
	if err != nil {
		return err
	}
	return writeSecretFile(path, png)
}
