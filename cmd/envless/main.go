// Package main is the envless CLI entrypoint.
package main

import (
	"fmt"
	"os"

	"github.com/biliboss/envless/internal/ecmd"
)

var version = "dev"

func main() {
	root := ecmd.New(version)
	if err := root.Execute(); err != nil {
		fmt.Fprintln(os.Stderr, "envless:", err)
		os.Exit(1)
	}
}
