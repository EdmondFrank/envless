package ecmd

import (
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"

	"github.com/spf13/cobra"

	"github.com/envless-sh/envless/internal/store"
	"github.com/envless-sh/envless/pkg/envparse"
)

func newMigrateCmd() *cobra.Command {
	var envName string
	var keep bool
	cmd := &cobra.Command{
		Use:   "migrate FILE",
		Short: "encrypt a .env file into envless and gitignore the plaintext",
		Args:  cobra.ExactArgs(1),
		RunE: func(cmd *cobra.Command, args []string) error {
			cwd, err := os.Getwd()
			if err != nil {
				return err
			}
			src := args[0]
			data, err := os.ReadFile(src)
			if err != nil {
				return fmt.Errorf("read %s: %w", src, err)
			}
			entries, err := envparse.Parse(data)
			if err != nil {
				return fmt.Errorf("parse %s: %w", src, err)
			}
			kv := make(map[string]string, len(entries))
			for _, e := range entries {
				kv[e.Key] = e.Value
			}
			s := store.New(cwd)
			existing, err := s.Read(envName)
			if err != nil {
				return err
			}
			for k, v := range kv {
				existing[k] = v
			}
			if err := s.Write(envName, existing); err != nil {
				return err
			}
			pattern := filepath.Base(src)
			if err := appendGitignore(filepath.Join(cwd, ".gitignore"), pattern); err != nil {
				return err
			}
			fmt.Fprintf(cmd.OutOrStdout(), "MIGRATE  src=%s env=%s keys=%d\n", src, envName, len(kv))
			if !keep {
				if err := os.Remove(src); err != nil {
					return fmt.Errorf("remove %s: %w", src, err)
				}
				fmt.Fprintf(cmd.OutOrStdout(), "REMOVE   %s\n", src)
			}
			return nil
		},
	}
	cmd.Flags().StringVar(&envName, "env", "dev", "target environment")
	cmd.Flags().BoolVar(&keep, "keep", false, "keep the plaintext source file after migration")
	return cmd
}

func appendGitignore(path, pattern string) error {
	data, err := os.ReadFile(path)
	if err != nil && !errors.Is(err, os.ErrNotExist) {
		return fmt.Errorf("read .gitignore: %w", err)
	}
	for _, line := range strings.Split(string(data), "\n") {
		if strings.TrimSpace(line) == pattern {
			return nil
		}
	}
	if len(data) > 0 && !strings.HasSuffix(string(data), "\n") {
		data = append(data, '\n')
	}
	data = append(data, []byte(pattern+"\n")...)
	return os.WriteFile(path, data, 0o644)
}
