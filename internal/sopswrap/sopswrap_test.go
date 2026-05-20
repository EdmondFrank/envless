package sopswrap

import (
	"os"
	"os/exec"
	"path/filepath"
	"testing"
)

func requireBins(t *testing.T, bins ...string) {
	t.Helper()
	for _, b := range bins {
		if _, err := exec.LookPath(b); err != nil {
			t.Skipf("%s not installed: %v", b, err)
		}
	}
}

// genAgeIdentity produces a fresh age keypair via age-keygen; returns (pubkey, identityFilePath).
func genAgeIdentity(t *testing.T) (string, string) {
	t.Helper()
	requireBins(t, "age-keygen")
	dir := t.TempDir()
	keyFile := filepath.Join(dir, "id.key")
	out, err := exec.Command("age-keygen", "-o", keyFile).CombinedOutput()
	if err != nil {
		t.Fatalf("age-keygen: %v\n%s", err, out)
	}
	// age-keygen prints "Public key: age1..." to stderr (or stdout)
	// Parse from the key file: it has a comment line "# public key: age1..."
	data, err := os.ReadFile(keyFile)
	if err != nil {
		t.Fatalf("read keyfile: %v", err)
	}
	pub := parsePubKey(t, string(data))
	return pub, keyFile
}

func parsePubKey(t *testing.T, content string) string {
	t.Helper()
	const marker = "# public key: "
	for _, line := range splitLines(content) {
		if len(line) > len(marker) && line[:len(marker)] == marker {
			return line[len(marker):]
		}
	}
	t.Fatalf("no public key marker in identity file:\n%s", content)
	return ""
}

func splitLines(s string) []string {
	var out []string
	start := 0
	for i := 0; i < len(s); i++ {
		if s[i] == '\n' {
			out = append(out, s[start:i])
			start = i + 1
		}
	}
	if start < len(s) {
		out = append(out, s[start:])
	}
	return out
}

func TestRoundtrip(t *testing.T) {
	requireBins(t, "sops", "age", "age-keygen")
	pub, keyFile := genAgeIdentity(t)
	dst := filepath.Join(t.TempDir(), "secrets.env")

	want := map[string]string{
		"OPENAI_API_KEY": "sk-test-xyz",
		"DATABASE_URL":   "postgres://u:p@h:5432/db",
		"EMPTY":          "",
	}
	if err := Encrypt(dst, want, []string{pub}); err != nil {
		t.Fatalf("encrypt: %v", err)
	}

	got, err := Decrypt(dst, keyFile)
	if err != nil {
		t.Fatalf("decrypt: %v", err)
	}
	if len(got) != len(want) {
		t.Fatalf("len: want %d, got %d (%v)", len(want), len(got), got)
	}
	for k, v := range want {
		if got[k] != v {
			t.Fatalf("%s: want %q, got %q", k, v, got[k])
		}
	}
}
