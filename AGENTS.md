# diorama-vm

Single-repo container host for local macOS (Apple Silicon): Swift VZ launcher + vendored u-root + gVisor runsc.

- **Artifacts:** only under `artifacts/` (gitignored blobs).
- **Vendor:** `vendor/u-root/` is vendored upstream; change only when bumping the pin.
- **Build:** run `make` targets from repo root; scripts use `scripts/diorama-vm-root.sh` or `DIORAMA_VM_ROOT`.
