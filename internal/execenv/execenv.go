// Package execenv builds process environments and runs commands with injected secrets.
package execenv

import (
	"errors"
	"fmt"
	"io"
	"os/exec"
	"sort"
	"strings"
)

// BuildEnv merges parent process env with the provided key/value map.
// Keys in kv override matching keys in parent. Returns a deterministic
// sorted []string of KEY=VALUE entries suitable for exec.Cmd.Env or syscall.Exec.
func BuildEnv(parent []string, kv map[string]string) []string {
	merged := map[string]string{}
	for _, e := range parent {
		k, v, ok := strings.Cut(e, "=")
		if !ok {
			continue
		}
		merged[k] = v
	}
	for k, v := range kv {
		merged[k] = v
	}
	out := make([]string, 0, len(merged))
	for k, v := range merged {
		out = append(out, k+"="+v)
	}
	sort.Strings(out)
	return out
}

// ExitError is returned when the child process exits with a non-zero status.
type ExitError struct {
	Code int
}

func (e *ExitError) Error() string { return fmt.Sprintf("exit status %d", e.Code) }

// Run executes argv with the given environment. argv[0] is resolved via PATH.
// stdin/stdout/stderr may be nil to inherit /dev/null behavior.
// Returns *ExitError when the child exits non-zero, or a wrapped error on launch failure.
func Run(argv, env []string, stdin io.Reader, stdout, stderr io.Writer) error {
	if len(argv) == 0 {
		return errors.New("execenv: empty argv")
	}
	cmd := exec.Command(argv[0], argv[1:]...)
	cmd.Env = env
	cmd.Stdin = stdin
	cmd.Stdout = stdout
	cmd.Stderr = stderr
	err := cmd.Run()
	if err == nil {
		return nil
	}
	var xe *exec.ExitError
	if errors.As(err, &xe) {
		return &ExitError{Code: xe.ExitCode()}
	}
	return fmt.Errorf("execenv: %w", err)
}
