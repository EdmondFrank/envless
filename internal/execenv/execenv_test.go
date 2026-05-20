package execenv

import (
	"strings"
	"testing"
)

func TestBuildEnv(t *testing.T) {
	cases := []struct {
		name   string
		parent []string
		kv     map[string]string
		want   []string
	}{
		{
			name:   "kv overrides parent",
			parent: []string{"PATH=/usr/bin", "FOO=old"},
			kv:     map[string]string{"FOO": "new"},
			want:   []string{"FOO=new", "PATH=/usr/bin"},
		},
		{
			name:   "kv adds new keys",
			parent: []string{"PATH=/usr/bin"},
			kv:     map[string]string{"BAR": "1", "BAZ": "2"},
			want:   []string{"BAR=1", "BAZ=2", "PATH=/usr/bin"},
		},
		{
			name:   "empty kv passthrough",
			parent: []string{"A=1", "B=2"},
			kv:     nil,
			want:   []string{"A=1", "B=2"},
		},
		{
			name:   "value with equals sign preserved",
			parent: nil,
			kv:     map[string]string{"URL": "https://x.com?a=b"},
			want:   []string{"URL=https://x.com?a=b"},
		},
		{
			name:   "value with empty string allowed",
			parent: nil,
			kv:     map[string]string{"A": ""},
			want:   []string{"A="},
		},
		{
			name:   "deterministic sort order",
			parent: nil,
			kv:     map[string]string{"Z": "1", "A": "2", "M": "3"},
			want:   []string{"A=2", "M=3", "Z=1"},
		},
		{
			name:   "parent entry without equals is dropped",
			parent: []string{"BROKEN", "OK=1"},
			kv:     nil,
			want:   []string{"OK=1"},
		},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			got := BuildEnv(tc.parent, tc.kv)
			assertEqual(t, got, tc.want)
		})
	}
}

func TestRun_InjectsEnvIntoChild(t *testing.T) {
	var stdout strings.Builder
	env := BuildEnv(nil, map[string]string{"ENVLESS_TEST": "hello"})
	err := Run([]string{"sh", "-c", "echo $ENVLESS_TEST"}, env, nil, &stdout, nil)
	if err != nil {
		t.Fatalf("run: %v", err)
	}
	if got := strings.TrimSpace(stdout.String()); got != "hello" {
		t.Fatalf("want %q, got %q", "hello", got)
	}
}

func TestRun_DoesNotLeakUnsetParentEnv(t *testing.T) {
	var stdout strings.Builder
	// Build env with only ENVLESS_TEST set, no PATH.
	env := []string{"ENVLESS_TEST=only"}
	// `set` prints all env vars in sh; we look for the expected one and absence of HOME.
	err := Run([]string{"/bin/sh", "-c", "env"}, env, nil, &stdout, nil)
	if err != nil {
		t.Fatalf("run: %v", err)
	}
	out := stdout.String()
	if !strings.Contains(out, "ENVLESS_TEST=only") {
		t.Fatalf("expected ENVLESS_TEST=only in env output: %s", out)
	}
	if strings.Contains(out, "HOME=") {
		t.Fatalf("HOME leaked from parent into child: %s", out)
	}
}

func TestRun_PropagatesExitCode(t *testing.T) {
	err := Run([]string{"sh", "-c", "exit 7"}, nil, nil, nil, nil)
	ec, ok := err.(*ExitError)
	if !ok {
		t.Fatalf("want *ExitError, got %T (%v)", err, err)
	}
	if ec.Code != 7 {
		t.Fatalf("want exit code 7, got %d", ec.Code)
	}
}

func assertEqual(t *testing.T, got, want []string) {
	t.Helper()
	if len(got) != len(want) {
		t.Fatalf("len: want %d, got %d (%v)", len(want), len(got), got)
	}
	for i := range want {
		if got[i] != want[i] {
			t.Fatalf("[%d]: want %q, got %q", i, want[i], got[i])
		}
	}
}
