---
title: Testing
description: Unit tests, e2e suite, and the testing conventions to follow when adding code.
---

`envless` keeps a small, fast test surface. The whole suite runs in
under three seconds on a laptop. The pattern: colocated unit tests,
plus a top-level `e2e/` package that builds the real binary and shells
out.

## Running the suite

```bash
make test
# or
go test -count=1 ./...
```

CI runs `go test -race -count=1 ./...` (see
[`.github/workflows/ci.yml`][gh-ci]). `-race` adds the data-race
detector; we want it green on every PR.

## Layout

| Path | Style | Purpose |
|---|---|---|
| `pkg/envparse/envparse_test.go` | Table-driven | Pure-logic parser tests. No I/O. |
| `internal/execenv/execenv_test.go` | Table-driven | Env merge logic + `Run` against `/bin/sh`. |
| `internal/sopswrap/sopswrap_test.go` | Skip-if-missing | Roundtrip through real `sops` + `age`. |
| `internal/store/store_test.go` | Skip-if-missing | Full filesystem behaviour. |
| `e2e/e2e_test.go` | Subprocess | Builds the binary in `TestMain` and runs it as a black box. |

The e2e suite is the executable spec — when a behaviour changes, the
e2e test changes too. See [Concepts → Lifecycle of a secret](../../concepts/lifecycle/)
for what each e2e case covers.

## The "skip if missing" pattern

Tests that require `age-keygen` or `sops` use this helper from
[`e2e/e2e_test.go`][gh-e2e]:

```go
func skipIfMissing(t *testing.T, bins ...string) {
    t.Helper()
    for _, b := range bins {
        if _, err := exec.LookPath(b); err != nil {
            t.Skipf("%s not installed", b)
        }
    }
}
```

Use it at the top of any test that shells out. CI installs both
binaries, so the skip only happens locally for contributors without
them.

## Writing a new test

For a new subcommand, add two:

1. **Unit test** next to the implementation. Keep it pure-logic
   wherever possible — use `cobra.Command.SetIn/SetOut/SetErr` to
   inject buffers.
2. **E2E case** in `e2e/e2e_test.go`. Follow the existing pattern:
   `t.TempDir()` per test, `envlessRun(t, dir, stdin, args...)`,
   assert on stdout/stderr/exit code.

Table-driven where it pays off:

```go
func TestParse(t *testing.T) {
    cases := []struct {
        name string
        in   string
        want []Entry
    }{
        {"empty", "", nil},
        {"single", "A=1\n", []Entry{{"A", "1"}}},
        // ...
    }
    for _, tc := range cases {
        t.Run(tc.name, func(t *testing.T) {
            got, err := Parse([]byte(tc.in))
            if err != nil { t.Fatal(err) }
            if !reflect.DeepEqual(got, tc.want) {
                t.Fatalf("got %v, want %v", got, tc.want)
            }
        })
    }
}
```

## What to assert in e2e

- **Exit code** — see [Exit codes](../../reference/exit-codes/).
- **Stdout content**. The caveman convention means it is predictable.
- **File side-effects** — `.envless/`, `secrets/`, `.gitignore`.
- **Never** assert on the encrypted bytes of `secrets/*.env.enc`
  directly — sops includes timestamps and per-call randomness.

## What NOT to do

- **No mocks for `sops` or `age`.** They are real binaries; the e2e
  suite uses them. Mocking the boundary defeats the test's purpose.
- **No `t.Sleep`** to "wait for sops to finish." `exec.Cmd.Run()` is
  synchronous. If you find yourself wanting a sleep, look harder.
- **No global fixtures** beyond what `TestMain` sets up. Each test
  gets its own `t.TempDir()`.
- **No flaky network calls.** v0.0.1 makes none — keep it that way.

## Suite-time budget

We target sub-3-second `go test ./...` because slow tests stop getting
run. The e2e cases that shell out to `sops` each take ~200ms; that is
the budget, not a license to add more. If a new case takes longer than
500ms, profile it.

[gh-ci]: https://github.com/biliboss/envless/blob/main/.github/workflows/ci.yml
[gh-e2e]: https://github.com/biliboss/envless/blob/main/e2e/e2e_test.go
