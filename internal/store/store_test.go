package store

import (
	"os/exec"
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

func TestInit_CreatesIdentityAndReturnsPubkey(t *testing.T) {
	requireBins(t, "age-keygen")
	s := New(t.TempDir())
	if err := s.Init(); err != nil {
		t.Fatalf("Init: %v", err)
	}
	pub, err := s.PubKey()
	if err != nil {
		t.Fatalf("PubKey: %v", err)
	}
	if len(pub) < 10 || pub[:4] != "age1" {
		t.Fatalf("want age1... pubkey, got %q", pub)
	}
}

func TestInit_Idempotent(t *testing.T) {
	requireBins(t, "age-keygen")
	s := New(t.TempDir())
	if err := s.Init(); err != nil {
		t.Fatalf("first init: %v", err)
	}
	pub1, _ := s.PubKey()
	if err := s.Init(); err != nil {
		t.Fatalf("second init: %v", err)
	}
	pub2, _ := s.PubKey()
	if pub1 != pub2 {
		t.Fatalf("identity changed across Init calls: %q -> %q", pub1, pub2)
	}
}

func TestSetGet_Roundtrip(t *testing.T) {
	requireBins(t, "age-keygen", "sops")
	s := New(t.TempDir())
	if err := s.Init(); err != nil {
		t.Fatalf("Init: %v", err)
	}
	if err := s.Set("dev", "OPENAI_API_KEY", "sk-test-xyz"); err != nil {
		t.Fatalf("Set: %v", err)
	}
	val, ok, err := s.Get("dev", "OPENAI_API_KEY")
	if err != nil {
		t.Fatalf("Get: %v", err)
	}
	if !ok || val != "sk-test-xyz" {
		t.Fatalf("Get: want sk-test-xyz, got %q ok=%v", val, ok)
	}
}

func TestRead_EmptyWhenNoFile(t *testing.T) {
	requireBins(t, "age-keygen")
	s := New(t.TempDir())
	if err := s.Init(); err != nil {
		t.Fatalf("Init: %v", err)
	}
	kv, err := s.Read("dev")
	if err != nil {
		t.Fatalf("Read: %v", err)
	}
	if len(kv) != 0 {
		t.Fatalf("want empty map, got %v", kv)
	}
}

func TestSet_PreservesExistingKeys(t *testing.T) {
	requireBins(t, "age-keygen", "sops")
	s := New(t.TempDir())
	if err := s.Init(); err != nil {
		t.Fatalf("Init: %v", err)
	}
	for k, v := range map[string]string{"A": "1", "B": "2"} {
		if err := s.Set("dev", k, v); err != nil {
			t.Fatalf("Set %s: %v", k, err)
		}
	}
	if err := s.Set("dev", "C", "3"); err != nil {
		t.Fatalf("Set C: %v", err)
	}
	kv, err := s.Read("dev")
	if err != nil {
		t.Fatalf("Read: %v", err)
	}
	for k, want := range map[string]string{"A": "1", "B": "2", "C": "3"} {
		if kv[k] != want {
			t.Fatalf("%s: want %q, got %q", k, want, kv[k])
		}
	}
}

func TestKeys_SortedNoValues(t *testing.T) {
	requireBins(t, "age-keygen", "sops")
	s := New(t.TempDir())
	if err := s.Init(); err != nil {
		t.Fatalf("Init: %v", err)
	}
	for _, k := range []string{"Z", "A", "M"} {
		if err := s.Set("dev", k, "v"); err != nil {
			t.Fatalf("Set %s: %v", k, err)
		}
	}
	keys, err := s.Keys("dev")
	if err != nil {
		t.Fatalf("Keys: %v", err)
	}
	want := []string{"A", "M", "Z"}
	if len(keys) != len(want) {
		t.Fatalf("len: want %d, got %d (%v)", len(want), len(keys), keys)
	}
	for i := range want {
		if keys[i] != want[i] {
			t.Fatalf("[%d]: want %q, got %q", i, want[i], keys[i])
		}
	}
}
