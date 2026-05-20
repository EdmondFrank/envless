package ecmd

import (
	"fmt"
	"os"

	"github.com/spf13/cobra"

	"github.com/envless-sh/envless/internal/store"
)

func newGetCmd() *cobra.Command {
	var envName string
	var confirm bool
	cmd := &cobra.Command{
		Use:   "get KEY",
		Short: "print a secret value (requires --confirm)",
		Args:  cobra.ExactArgs(1),
		RunE: func(cmd *cobra.Command, args []string) error {
			if !confirm {
				return fmt.Errorf("printing a secret requires --confirm")
			}
			cwd, err := os.Getwd()
			if err != nil {
				return err
			}
			s := store.New(cwd)
			val, ok, err := s.Get(envName, args[0])
			if err != nil {
				return err
			}
			if !ok {
				return fmt.Errorf("key %q not found in env %q", args[0], envName)
			}
			fmt.Fprintln(cmd.OutOrStdout(), val)
			return nil
		},
	}
	cmd.Flags().StringVar(&envName, "env", "dev", "environment name")
	cmd.Flags().BoolVar(&confirm, "confirm", false, "confirm intent to print plaintext")
	_ = os.Stderr
	return cmd
}
