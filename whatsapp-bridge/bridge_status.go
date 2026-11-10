package main

import (
	"regexp"
	"strings"
)

var redactLong = regexp.MustCompile(`[A-Za-z0-9+/=_-]{32,}`)
var redactWords = regexp.MustCompile(`(?i)token|bearer|secret|payload|session|\bqr\b|\bkey\b|ref=`)

func bridgeFailureClass(err error) string {
	if err == nil {
		return "none"
	}
	msg := err.Error()
	switch {
	case strings.Contains(msg, "connect failed"):
		return "connect_failed"
	case strings.Contains(msg, "pairing timed out"):
		return "pairing_timeout"
	case strings.Contains(msg, "pairing ended"):
		return "pairing_closed"
	case strings.Contains(msg, "refusing to connect"):
		return "pair_disabled"
	case strings.Contains(msg, "pairing code is empty"):
		return "image_rejected"
	default:
		return "start_rejected"
	}
}

func bridgeFailureLine(err error) string {
	return "bridge_not_started class=" + bridgeFailureClass(err)
}

func bridgeFailureDetail(err error) string {
	if err == nil {
		return ""
	}
	msg := strings.ReplaceAll(err.Error(), "\n", " ")
	msg = redactLong.ReplaceAllString(msg, "redacted")
	msg = redactWords.ReplaceAllString(msg, "redacted")
	msg = strings.Join(strings.Fields(msg), " ")
	if len(msg) > 180 {
		msg = msg[:180]
	}
	return "bridge_detail " + msg
}
