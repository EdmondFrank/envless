package ecmd

import (
	"errors"
	"os"

	"github.com/spf13/cobra"

	"github.com/biliboss/envless/internal/execenv"
	"github.com/biliboss/envless/internal/store"
)

func newExecCmd() *cobra.Command {
	var envName string
	cmd := &cobra.Command{
		Use:                "exec [--env=ENV] -- CMD [ARGS...]",
		Short:              "run a command with secrets injected as env vars",
		DisableFlagParsing: false,
		RunE: func(cmd *cobra.Command, args []string) error {
			if len(args) == 0 {
				return errors.New("exec: missing command")
			}
			cwd, err := os.Getwd()
			if err != nil {
				return err
			}
			s := store.New(cwd)
			kv, err := s.Read(envName)
			if err != nil {
				return err
			}
			child := execenv.BuildEnv(os.Environ(), kv)
			runErr := execenv.Run(args, child, os.Stdin, cmd.OutOrStdout(), cmd.ErrOrStderr())
			if runErr == nil {
				return nil
			}
			var xe *execenv.ExitError
			if errors.As(runErr, &xe) {
				os.Exit(xe.Code)
			}
			return runErr
		},
	}
	cmd.Flags().StringVar(&envName, "env", "dev", "environment name")
	return cmd
}
