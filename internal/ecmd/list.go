package ecmd

import (
	"fmt"
	"os"

	"github.com/spf13/cobra"

	"github.com/biliboss/envless/internal/store"
)

func newListCmd() *cobra.Command {
	var envName string
	cmd := &cobra.Command{
		Use:   "list",
		Short: "list keys in an env (does not print values)",
		Args:  cobra.NoArgs,
		RunE: func(cmd *cobra.Command, args []string) error {
			cwd, err := os.Getwd()
			if err != nil {
				return err
			}
			s := store.New(cwd)
			keys, err := s.Keys(envName)
			if err != nil {
				return err
			}
			for _, k := range keys {
				fmt.Fprintln(cmd.OutOrStdout(), k)
			}
			return nil
		},
	}
	cmd.Flags().StringVar(&envName, "env", "dev", "environment name")
	return cmd
}
