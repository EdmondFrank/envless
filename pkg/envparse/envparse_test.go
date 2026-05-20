package envparse

import "testing"

func TestParse(t *testing.T) {
	cases := []struct {
		name string
		in   string
		want []Entry
	}{
		{
			name: "single simple assignment",
			in:   "KEY=value\n",
			want: []Entry{{"KEY", "value"}},
		},
		{
			name: "multiple lines preserve order",
			in:   "A=1\nB=2\nC=3\n",
			want: []Entry{{"A", "1"}, {"B", "2"}, {"C", "3"}},
		},
		{
			name: "blank lines and comments ignored",
			in:   "# header\n\nA=1\n   # indented comment\nB=2\n",
			want: []Entry{{"A", "1"}, {"B", "2"}},
		},
		{
			name: "whitespace around key trimmed",
			in:   "  A = 1\nB=2\n",
			want: []Entry{{"A", "1"}, {"B", "2"}},
		},
		{
			name: "double-quoted value strips outer quotes",
			in:   `A="hello world"` + "\n",
			want: []Entry{{"A", "hello world"}},
		},
		{
			name: "single-quoted value strips outer quotes",
			in:   "A='hello world'\n",
			want: []Entry{{"A", "hello world"}},
		},
		{
			name: "empty value valid",
			in:   "A=\nB=2\n",
			want: []Entry{{"A", ""}, {"B", "2"}},
		},
		{
			name: "inline comment after unquoted value",
			in:   "A=1 # trailing\nB=2\n",
			want: []Entry{{"A", "1"}, {"B", "2"}},
		},
		{
			name: "hash inside quoted value preserved",
			in:   `A="not # a comment"` + "\n",
			want: []Entry{{"A", "not # a comment"}},
		},
		{
			name: "equals inside value preserved (split first only)",
			in:   "URL=https://x.com?a=b&c=d\n",
			want: []Entry{{"URL", "https://x.com?a=b&c=d"}},
		},
		{
			name: "trailing CRLF tolerated",
			in:   "A=1\r\nB=2\r\n",
			want: []Entry{{"A", "1"}, {"B", "2"}},
		},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			got, err := Parse([]byte(tc.in))
			if err != nil {
				t.Fatalf("unexpected error: %v", err)
			}
			assertEntries(t, got, tc.want)
		})
	}
}

func assertEntries(t *testing.T, got, want []Entry) {
	t.Helper()
	if len(got) != len(want) {
		t.Fatalf("len: want %d, got %d (%+v)", len(want), len(got), got)
	}
	for i := range want {
		if got[i] != want[i] {
			t.Fatalf("entry %d: want %+v, got %+v", i, want[i], got[i])
		}
	}
}
