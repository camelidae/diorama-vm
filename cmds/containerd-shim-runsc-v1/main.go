// Binary containerd-shim-runsc-v1 is the gVisor containerd shim, repackaged
// under its exec'd name so gobusybox registers it as
// "containerd-shim-runsc-v1" (gbb registers each command under its source
// directory basename; see cmds/README.md).
package main

import (
	"os"

	"gvisor.dev/gvisor/shim/v1/cli"
)

func main() {
	// TEMPORARY debug: mirror stderr to tmpfs; boot.sh cats it.
	if f, err := os.OpenFile("/tmp/shim-debug.log", os.O_CREATE|os.O_APPEND|os.O_WRONLY, 0o644); err == nil {
		os.Stderr = f
		defer f.Close()
		cli.Main()
		return
	}
	cli.Main()
}
