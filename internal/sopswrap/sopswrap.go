// Package sopswrap wraps the sops binary to encrypt and decrypt dotenv-format secret files.
package sopswrap

import (
	"bytes"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strings"

	"github.com/biliboss/envless/pkg/envparse"
)

// Encrypt serializes kv as a dotenv document and writes a sops-encrypted file at dst.
// recipients are age public keys (age1...). At least one recipient is required.
func Encrypt(dst string, kv map[string]string, recipients []string) error {
	if len(recipients) == 0 {
		return fmt.Errorf("sopswrap: at least one age recipient required")
	}
	if err := os.MkdirAll(filepath.Dir(dst), 0o755); err != nil {
		return fmt.Errorf("sopswrap: mkdir: %w", err)
	}
	plain := renderDotenv(kv)
	tmp, err := os.CreateTemp(filepath.Dir(dst), ".envless-enc-*.env")
	if err != nil {
		return fmt.Errorf("sopswrap: tempfile: %w", err)
	}
	tmpPath := tmp.Name()
	defer os.Remove(tmpPath)
	if _, err := tmp.Write(plain); err != nil {
		tmp.Close()
		return fmt.Errorf("sopswrap: write plain: %w", err)
	}
	if err := tmp.Close(); err != nil {
		return fmt.Errorf("sopswrap: close: %w", err)
	}

	cmd := exec.Command("sops",
		"encrypt",
		"--input-type", "dotenv",
		"--output-type", "dotenv",
		"--age", strings.Join(recipients, ","),
		tmpPath,
	)
	var stdout, stderr bytes.Buffer
	cmd.Stdout = &stdout
	cmd.Stderr = &stderr
	if err := cmd.Run(); err != nil {
		return fmt.Errorf("sopswrap: sops encrypt: %w (stderr: %s)", err, stderr.String())
	}
	if err := os.WriteFile(dst, stdout.Bytes(), 0o644); err != nil {
		return fmt.Errorf("sopswrap: write dst: %w", err)
	}
	return nil
}

// Decrypt reads a sops-encrypted dotenv file and returns its key/value map.
// identityFile is the path to an age identity file.
func Decrypt(src, identityFile string) (map[string]string, error) {
	cmd := exec.Command("sops",
		"decrypt",
		"--input-type", "dotenv",
		"--output-type", "dotenv",
		src,
	)
	if identityFile != "" {
		cmd.Env = append(os.Environ(), "SOPS_AGE_KEY_FILE="+identityFile)
	}
	var stdout, stderr bytes.Buffer
	cmd.Stdout = &stdout
	cmd.Stderr = &stderr
	if err := cmd.Run(); err != nil {
		return nil, fmt.Errorf("sopswrap: sops decrypt: %w (stderr: %s)", err, stderr.String())
	}
	entries, err := envparse.Parse(stdout.Bytes())
	if err != nil {
		return nil, fmt.Errorf("sopswrap: parse decrypted: %w", err)
	}
	out := make(map[string]string, len(entries))
	for _, e := range entries {
		out[e.Key] = e.Value
	}
	return out, nil
}

func renderDotenv(kv map[string]string) []byte {
	keys := make([]string, 0, len(kv))
	for k := range kv {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	var b bytes.Buffer
	for _, k := range keys {
		b.WriteString(k)
		b.WriteByte('=')
		b.WriteString(kv[k])
		b.WriteByte('\n')
	}
	return b.Bytes()
}
