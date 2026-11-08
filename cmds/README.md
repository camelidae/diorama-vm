# gVisor wrapper commands for the gobusybox (gbb) initramfs.
#
# gbb registers each command under its source directory basename, with no
# rename mechanism. containerd execs the shim as `containerd-shim-runsc-v1`
# and runsc execs fixed sidecar names from `gvisor-bin/`, so each wrapper
# directory here is named exactly what the caller exec's, containing a
# `main` that calls the upstream library entry point.
#
# Current wrappers:
# - containerd-shim-runsc-v1/ → gvisor.dev/gvisor/shim/v1/cli.Main()
# - dios-vsockd/ → guest vsock→containerd socket relay (phase 5)
#
# Host-side tools (built for darwin, never shipped in the initramfs):
# - hostctr/ → gRPC test client driving the guest daemon over
#   artifacts/run/containerd.sock (phase 5 gate: version, images,
#   remote run with exit-code checks). Must pin overlayfs + linux/arm64
#   explicitly: the darwin client defaults to native/darwin otherwise.
#
# Phase 6 decision (keep runsc standalone): folding runsc into bb would
# dedup only the shared Go runtime (~5 MiB of the 47 MiB runsc binary;
# the rest is sentry/machine code bb doesn't link) while risking runsc's
# /proc/self/exe re-exec model for its sandbox/gofer/boot children, which
# the argv[0] patch set would have to cover. Not justified; runsc stays a
# separate stripped release binary. Revisit only if initramfs size
# becomes a boot-time bottleneck.
