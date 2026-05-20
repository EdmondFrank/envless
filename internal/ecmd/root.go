// Package ecmd wires the envless cobra command tree.
package ecmd

import (
	"github.com/spf13/cobra"
)

// New builds the root envless command. version is injected at build time.
func New(version string) *cobra.Command {
	root := &cobra.Command{
		Use:           "envless",
		Short:         "agent-first secrets, zero .env",
		Version:       version,
		SilenceUsage:  true,
		SilenceErrors: true,
	}
	root.AddCommand(
		newInitCmd(),
		newSetCmd(),
		newGetCmd(),
		newListCmd(),
		newExecCmd(),
		newMigrateCmd(),
	)
	return root
}
