package main

import (
	"fmt"
	"net/url"
	"os"
	"path/filepath"
	"strings"
)

// Config is the only place an instance is allowed to keep files.
// Paths are absolute and contained. There is no working-directory fallback.
type Config struct {
	InstanceDir string
	Pair        bool
}

func (c Config) SessionDB() string   { return filepath.Join(c.InstanceDir, "session.db") }
func (c Config) MessagesDB() string  { return filepath.Join(c.InstanceDir, "messages.db") }
func (c Config) MediaDir() string    { return filepath.Join(c.InstanceDir, "media") }
func (c Config) SocketPath() string  { return filepath.Join(c.InstanceDir, "bridge.sock") }
func (c Config) TokenPath() string   { return filepath.Join(c.InstanceDir, "bridge.token") }
func (c Config) PIDPath() string     { return filepath.Join(c.InstanceDir, "bridge.pid") }
func (c Config) PairingPath() string { return filepath.Join(c.InstanceDir, "pairing.payload") }

// LoadConfigFromEnv reads the instance location from the environment.
// WA_INSTANCE_DIR is required. WA_DENY_INSTANCE_DIRS and WA_REPO_ROOT are
// optional absolute paths the process must not use or nest inside.
// WA_PAIR=1 allows a future pairing flow. It does not connect by itself.
func LoadConfigFromEnv() (Config, error) {
	pair := os.Getenv("WA_PAIR") == "1"
	return LoadConfig(os.Getenv("WA_INSTANCE_DIR"), os.Getenv("WA_DENY_INSTANCE_DIRS"), os.Getenv("WA_REPO_ROOT"), pair)
}

// LoadConfig validates an instance directory and creates it with mode 0700.
// denyRaw and repoRoot use the platform list separator (colon on Linux).
func LoadConfig(instanceDir, denyRaw, repoRoot string, pair bool) (Config, error) {
	if strings.TrimSpace(instanceDir) == "" {
		return Config{}, fmt.Errorf("WA_INSTANCE_DIR is required and must be absolute")
	}
	if !filepath.IsAbs(instanceDir) {
		return Config{}, fmt.Errorf("WA_INSTANCE_DIR must be absolute")
	}
	cleaned := filepath.Clean(instanceDir)
	if err := rejectListed(cleaned, repoRoot, denyRaw); err != nil {
		return Config{}, err
	}
	if err := os.MkdirAll(cleaned, 0700); err != nil {
		return Config{}, fmt.Errorf("create instance directory: %w", err)
	}
	if err := os.Chmod(cleaned, 0700); err != nil {
		return Config{}, fmt.Errorf("restrict instance directory: %w", err)
	}
	real, err := filepath.EvalSymlinks(cleaned)
	if err != nil {
		return Config{}, fmt.Errorf("resolve instance directory: %w", err)
	}
	if err := rejectListed(real, repoRoot, denyRaw); err != nil {
		return Config{}, err
	}
	return Config{InstanceDir: real, Pair: pair}, nil
}

func rejectListed(instance, repoRoot, denyRaw string) error {
	if repoRoot != "" {
		if err := rejectOverlap(instance, repoRoot, "repository"); err != nil {
			return err
		}
	}
	for _, part := range strings.Split(denyRaw, string(os.PathListSeparator)) {
		part = strings.TrimSpace(part)
		if part == "" {
			continue
		}
		if err := rejectOverlap(instance, part, "denied path"); err != nil {
			return err
		}
	}
	return nil
}

func rejectOverlap(instanceReal, other, label string) error {
	if !filepath.IsAbs(other) {
		return fmt.Errorf("%s must be absolute", label)
	}
	otherReal := filepath.Clean(other)
	if info, err := os.Lstat(other); err == nil {
		resolved, err := filepath.EvalSymlinks(other)
		if err != nil {
			return fmt.Errorf("resolve %s: %w", label, err)
		}
		otherReal = resolved
		_ = info
	}
	if sameOrNested(instanceReal, otherReal) || sameOrNested(otherReal, instanceReal) {
		return fmt.Errorf("instance directory overlaps %s", label)
	}
	return nil
}

func sameOrNested(child, parent string) bool {
	child = filepath.Clean(child)
	parent = filepath.Clean(parent)
	if child == parent {
		return true
	}
	rel, err := filepath.Rel(parent, child)
	if err != nil {
		return false
	}
	return rel != ".." && !strings.HasPrefix(rel, ".."+string(os.PathSeparator))
}

func (c Config) contain(path string) error {
	if !filepath.IsAbs(path) {
		return fmt.Errorf("path must be absolute")
	}
	parent := filepath.Dir(path)
	realParent, err := filepath.EvalSymlinks(parent)
	if err != nil {
		return fmt.Errorf("resolve parent: %w", err)
	}
	if !sameOrNested(realParent, c.InstanceDir) {
		return fmt.Errorf("path escapes instance directory")
	}
	if info, err := os.Lstat(path); err == nil && info.Mode()&os.ModeSymlink != 0 {
		real, err := filepath.EvalSymlinks(path)
		if err != nil {
			return err
		}
		if !sameOrNested(real, c.InstanceDir) {
			return fmt.Errorf("symlink escapes instance directory")
		}
	}
	return nil
}

func sqliteDSN(path string) (string, error) {
	if !filepath.IsAbs(path) {
		return "", fmt.Errorf("database path must be absolute")
	}
	if strings.ContainsAny(path, "?\x00") {
		return "", fmt.Errorf("database path contains unsupported characters")
	}
	u := url.URL{Scheme: "file", Path: path, RawQuery: "_foreign_keys=on", OmitHost: true}
	return u.String(), nil
}
