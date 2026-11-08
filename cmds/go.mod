module diorama-vm.cmds

go 1.27.3

require (
	github.com/containerd/containerd/v2 v2.1.5
	golang.org/x/sys v0.49.0
	gvisor.dev/gvisor v0.0.0
)

// v0.0.0 is not resolvable from the network, and workspace `use` alone does
// not satisfy module-graph loads issued from a different main module
// (vendor/u-root): the go command still tries to fetch go.mod at v0.0.0.
// Pin to the local checkout (populated by scripts/fetch-src.sh) instead.
// Relative to this file: diorama-vm/artifacts/.src/gvisor.
replace gvisor.dev/gvisor => ../artifacts/.src/gvisor

// Same treatment as gvisor: hostctr drives the guest daemon over the vsock
// bridge via the pinned containerd client (darwin builds need the local
// checkout; the published v2.1.5 module would also work where networked).
replace github.com/containerd/containerd/v2 => ../artifacts/.src/containerd
