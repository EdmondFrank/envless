package ecmd

import (
	"fmt"
	"io"
	"os"
	"strings"

	"github.com/spf13/cobra"

	"github.com/biliboss/envless/internal/store"
)

func newSetCmd() *cobra.Command {
	var envName string
	cmd := &cobra.Command{
		Use:   "set KEY",
		Short: "store a secret value from stdin",
		Args:  cobra.ExactArgs(1),
		RunE: func(cmd *cobra.Command, args []string) error {
			key := args[0]
			data, err := io.ReadAll(cmd.InOrStdin())
			if err != nil {
				return fmt.Errorf("read stdin: %w", err)
			}
			value := strings.TrimRight(string(data), "\n")
			cwd, err := os.Getwd()
			if err != nil {
				return err
			}
			s := store.New(cwd)
			if err := s.Set(envName, key, value); err != nil {
				return err
			}
			fmt.Fprintf(cmd.OutOrStdout(), "SET   env=%s key=%s\n", envName, key)
			return nil
		},
	}
	cmd.Flags().StringVar(&envName, "env", "dev", "environment name")
	return cmd
}
