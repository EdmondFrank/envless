package e2e_test

import (
	"bytes"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
)

var binPath string

func TestMain(m *testing.M) {
	// If BIN is set, run the suite against that prebuilt binary as-is.
	// This lets a foreign toolchain (e.g., the Zig port) reuse this suite
	// as a parity oracle without modifying any test assertion.
	if bin := os.Getenv("BIN"); bin != "" {
		binPath = bin
		os.Exit(m.Run())
	}
	tmp, err := os.MkdirTemp("", "envless-bin-")
	if err != nil {
		panic(err)
	}
	binPath = filepath.Join(tmp, "envless")
	cmd := exec.Command("go", "build", "-o", binPath, "../cmd/envless")
	cmd.Stderr = os.Stderr
	if err := cmd.Run(); err != nil {
		panic("build envless: " + err.Error())
	}
	code := m.Run()
	os.RemoveAll(tmp)
	os.Exit(code)
}

func skipIfMissing(t *testing.T, bins ...string) {
	t.Helper()
	for _, b := range bins {
		if _, err := exec.LookPath(b); err != nil {
			t.Skipf("%s not installed", b)
		}
	}
}

func envless(t *testing.T, dir string, stdin string, args ...string) (string, string, int) {
	t.Helper()
	cmd := exec.Command(binPath, args...)
	cmd.Dir = dir
	if stdin != "" {
		cmd.Stdin = strings.NewReader(stdin)
	}
	var stdout, stderr bytes.Buffer
	cmd.Stdout = &stdout
	cmd.Stderr = &stderr
	err := cmd.Run()
	code := 0
	if exitErr, ok := err.(*exec.ExitError); ok {
		code = exitErr.ExitCode()
	} else if err != nil {
		t.Fatalf("envless %v: %v\nstderr: %s", args, err, stderr.String())
	}
	return stdout.String(), stderr.String(), code
}

func TestE2E_VersionFlag(t *testing.T) {
	out, _, code := envless(t, "", "", "--version")
	if code != 0 {
		t.Fatalf("--version exit=%d", code)
	}
	if strings.TrimSpace(out) == "" {
		t.Fatalf("expected non-empty version output")
	}
}

func TestE2E_InitSetExecRoundtrip(t *testing.T) {
	skipIfMissing(t, "age-keygen", "sops", "sh")
	dir := t.TempDir()

	// 1. init
	_, _, code := envless(t, dir, "", "init")
	if code != 0 {
		t.Fatalf("init exit=%d", code)
	}
	if _, err := os.Stat(filepath.Join(dir, ".envless", "identity.key")); err != nil {
		t.Fatalf("identity not created: %v", err)
	}

	// 2. set via stdin
	_, _, code = envless(t, dir, "sk-test-xyz", "set", "OPENAI_API_KEY")
	if code != 0 {
		t.Fatalf("set exit=%d", code)
	}

	// 3. exec — child sees the secret in its env
	stdout, _, code := envless(t, dir, "", "exec", "--", "/bin/sh", "-c", "echo $OPENAI_API_KEY")
	if code != 0 {
		t.Fatalf("exec exit=%d", code)
	}
	if got := strings.TrimSpace(stdout); got != "sk-test-xyz" {
		t.Fatalf("want sk-test-xyz, got %q", got)
	}
}

func TestE2E_MultiEnvIsolation(t *testing.T) {
	skipIfMissing(t, "age-keygen", "sops", "sh")
	dir := t.TempDir()
	envlessRun(t, dir, "", "init")
	envlessRun(t, dir, "dev-val", "set", "TOKEN")
	envlessRun(t, dir, "prod-val", "set", "TOKEN", "--env=prod")

	devOut, _, _ := envless(t, dir, "", "exec", "--", "/bin/sh", "-c", "echo $TOKEN")
	if strings.TrimSpace(devOut) != "dev-val" {
		t.Fatalf("dev: want dev-val, got %q", devOut)
	}
	prodOut, _, _ := envless(t, dir, "", "exec", "--env=prod", "--", "/bin/sh", "-c", "echo $TOKEN")
	if strings.TrimSpace(prodOut) != "prod-val" {
		t.Fatalf("prod: want prod-val, got %q", prodOut)
	}
}

func TestE2E_List(t *testing.T) {
	skipIfMissing(t, "age-keygen", "sops")
	dir := t.TempDir()
	envlessRun(t, dir, "", "init")
	envlessRun(t, dir, "v1", "set", "A")
	envlessRun(t, dir, "v2", "set", "B")
	stdout, _, code := envless(t, dir, "", "list")
	if code != 0 {
		t.Fatalf("list exit=%d", code)
	}
	out := stdout
	if !strings.Contains(out, "A") || !strings.Contains(out, "B") {
		t.Fatalf("want A and B in list output:\n%s", out)
	}
	if strings.Contains(out, "v1") || strings.Contains(out, "v2") {
		t.Fatalf("list must not print values:\n%s", out)
	}
}

func TestE2E_GetRequiresConfirm(t *testing.T) {
	skipIfMissing(t, "age-keygen", "sops")
	dir := t.TempDir()
	envlessRun(t, dir, "", "init")
	envlessRun(t, dir, "secret-val", "set", "TOKEN")
	// Without --confirm: should refuse.
	_, stderr, code := envless(t, dir, "", "get", "TOKEN")
	if code == 0 {
		t.Fatalf("get without --confirm should fail")
	}
	if !strings.Contains(stderr, "confirm") {
		t.Fatalf("want stderr mentioning confirm, got: %s", stderr)
	}
	// With --confirm: should print.
	stdout, _, code := envless(t, dir, "", "get", "TOKEN", "--confirm")
	if code != 0 {
		t.Fatalf("get --confirm exit=%d", code)
	}
	if strings.TrimSpace(stdout) != "secret-val" {
		t.Fatalf("want secret-val, got %q", stdout)
	}
}

func TestE2E_Migrate(t *testing.T) {
	skipIfMissing(t, "age-keygen", "sops")
	dir := t.TempDir()
	envlessRun(t, dir, "", "init")

	dotenv := filepath.Join(dir, ".env")
	if err := os.WriteFile(dotenv, []byte("A=1\nB=2\nURL=https://x.com?a=b\n"), 0o644); err != nil {
		t.Fatalf("seed .env: %v", err)
	}
	envlessRun(t, dir, "", "migrate", ".env")

	// .env keys should now be retrievable through the store.
	stdout, _, code := envless(t, dir, "", "list")
	if code != 0 {
		t.Fatalf("list exit=%d", code)
	}
	for _, k := range []string{"A", "B", "URL"} {
		if !strings.Contains(stdout, k) {
			t.Fatalf("want %s in list, got:\n%s", k, stdout)
		}
	}
	// .env should be in .gitignore.
	gi, err := os.ReadFile(filepath.Join(dir, ".gitignore"))
	if err != nil {
		t.Fatalf("read .gitignore: %v", err)
	}
	if !strings.Contains(string(gi), ".env") {
		t.Fatalf(".env not in .gitignore:\n%s", gi)
	}
}

// envlessRun is like envless but fails the test on non-zero exit.
func envlessRun(t *testing.T, dir, stdin string, args ...string) {
	t.Helper()
	stdout, stderr, code := envless(t, dir, stdin, args...)
	if code != 0 {
		t.Fatalf("envless %v exit=%d\nstdout: %s\nstderr: %s", args, code, stdout, stderr)
	}
	_ = io.Discard
}
