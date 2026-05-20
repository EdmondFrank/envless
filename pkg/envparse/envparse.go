// Package envparse parses .env file content into ordered key-value entries.
package envparse

import (
	"bufio"
	"bytes"
	"strings"
)

// Entry is one assignment from a .env file.
type Entry struct {
	Key   string
	Value string
}

// Parse reads .env content and returns its entries in source order.
func Parse(content []byte) ([]Entry, error) {
	var out []Entry
	sc := bufio.NewScanner(bytes.NewReader(content))
	for sc.Scan() {
		line := strings.TrimSpace(sc.Text())
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		key, raw, ok := strings.Cut(line, "=")
		if !ok {
			continue
		}
		out = append(out, Entry{
			Key:   strings.TrimSpace(key),
			Value: parseValue(strings.TrimSpace(raw)),
		})
	}
	return out, sc.Err()
}

func parseValue(s string) string {
	if s == "" {
		return ""
	}
	if q := s[0]; q == '"' || q == '\'' {
		if end := strings.IndexByte(s[1:], q); end >= 0 {
			return s[1 : 1+end]
		}
		return s
	}
	if i := strings.Index(s, " #"); i >= 0 {
		return strings.TrimSpace(s[:i])
	}
	return s
}
