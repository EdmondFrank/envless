// Package store manages the local envless directory layout: .envless/ (identity, recipients)
// and secrets/ (per-env encrypted dotenv files).
package store

import (
	"bytes"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strings"

	"github.com/biliboss/envless/internal/sopswrap"
)

// Store represents an envless-managed repository rooted at Root.
type Store struct {
	Root string
}

// New returns a Store rooted at root.
func New(root string) *Store { return &Store{Root: root} }

// IdentityPath returns the canonical path to the local age identity file.
func (s *Store) IdentityPath() string {
	return filepath.Join(s.Root, ".envless", "identity.key")
}

// RecipientsPath returns the path to the recipients file (one pubkey per line).
func (s *Store) RecipientsPath() string {
	return filepath.Join(s.Root, ".envless", "recipients")
}

// SecretsPath returns the encrypted file path for an env.
func (s *Store) SecretsPath(env string) string {
	return filepath.Join(s.Root, "secrets", env+".env.enc")
}

// Init creates .envless/identity.key (via age-keygen) and seeds recipients with the
// new public key. Idempotent: if identity exists, returns nil.
func (s *Store) Init() error {
	dir := filepath.Join(s.Root, ".envless")
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return fmt.Errorf("store: mkdir .envless: %w", err)
	}
	id := s.IdentityPath()
	if _, err := os.Stat(id); err == nil {
		return nil // already initialized
	}
	cmd := exec.Command("age-keygen", "-o", id)
	var stderr bytes.Buffer
	cmd.Stderr = &stderr
	if err := cmd.Run(); err != nil {
		return fmt.Errorf("store: age-keygen: %w (stderr: %s)", err, stderr.String())
	}
	if err := os.Chmod(id, 0o600); err != nil {
		return fmt.Errorf("store: chmod identity: %w", err)
	}
	pub, err := s.PubKey()
	if err != nil {
		return err
	}
	if err := os.WriteFile(s.RecipientsPath(), []byte(pub+"\n"), 0o644); err != nil {
		return fmt.Errorf("store: write recipients: %w", err)
	}
	return nil
}

// Recipients returns the list of age public keys for env (currently env-agnostic,
// reads .envless/recipients). Future: per-env recipient files.
func (s *Store) Recipients(env string) ([]string, error) {
	data, err := os.ReadFile(s.RecipientsPath())
	if err != nil {
		return nil, fmt.Errorf("store: read recipients: %w", err)
	}
	var out []string
	for _, line := range strings.Split(string(data), "\n") {
		line = strings.TrimSpace(line)
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		out = append(out, line)
	}
	if len(out) == 0 {
		return nil, fmt.Errorf("store: no recipients in %s", s.RecipientsPath())
	}
	return out, nil
}

// Read returns the decrypted KV map for env. Empty map if the file doesn't exist yet.
func (s *Store) Read(env string) (map[string]string, error) {
	p := s.SecretsPath(env)
	if _, err := os.Stat(p); errors.Is(err, os.ErrNotExist) {
		return map[string]string{}, nil
	} else if err != nil {
		return nil, fmt.Errorf("store: stat %s: %w", p, err)
	}
	return sopswrap.Decrypt(p, s.IdentityPath())
}

// Write encrypts kv for env using current recipients.
func (s *Store) Write(env string, kv map[string]string) error {
	recipients, err := s.Recipients(env)
	if err != nil {
		return err
	}
	return sopswrap.Encrypt(s.SecretsPath(env), kv, recipients)
}

// Set performs read-modify-write of a single key.
func (s *Store) Set(env, key, value string) error {
	kv, err := s.Read(env)
	if err != nil {
		return err
	}
	kv[key] = value
	return s.Write(env, kv)
}

// Get fetches a single key. The bool reports whether the key exists.
func (s *Store) Get(env, key string) (string, bool, error) {
	kv, err := s.Read(env)
	if err != nil {
		return "", false, err
	}
	v, ok := kv[key]
	return v, ok, nil
}

// Keys returns the sorted key list for env (no values).
func (s *Store) Keys(env string) ([]string, error) {
	kv, err := s.Read(env)
	if err != nil {
		return nil, err
	}
	out := make([]string, 0, len(kv))
	for k := range kv {
		out = append(out, k)
	}
	sort.Strings(out)
	return out, nil
}

// PubKey returns the public key from the local identity file.
func (s *Store) PubKey() (string, error) {
	data, err := os.ReadFile(s.IdentityPath())
	if err != nil {
		return "", fmt.Errorf("store: read identity: %w", err)
	}
	const marker = "# public key: "
	for _, line := range strings.Split(string(data), "\n") {
		if strings.HasPrefix(line, marker) {
			return strings.TrimSpace(strings.TrimPrefix(line, marker)), nil
		}
	}
	return "", fmt.Errorf("store: no public key marker in %s", s.IdentityPath())
}
