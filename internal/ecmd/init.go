package ecmd

import (
	"fmt"
	"os"

	"github.com/spf13/cobra"

	"github.com/envless-sh/envless/internal/store"
)

func newInitCmd() *cobra.Command {
	return &cobra.Command{
		Use:   "init",
		Short: "initialize .envless/ in the current directory",
		Args:  cobra.NoArgs,
		RunE: func(cmd *cobra.Command, args []string) error {
			cwd, err := os.Getwd()
			if err != nil {
				return err
			}
			s := store.New(cwd)
			if err := s.Init(); err != nil {
				return err
			}
			pub, err := s.PubKey()
			if err != nil {
				return err
			}
			fmt.Fprintf(cmd.OutOrStdout(), "INIT  identity=%s pubkey=%s\n", s.IdentityPath(), pub)
			return nil
		},
	}
}
