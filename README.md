# diorama-vm

**u-root** initramfs with **gVisor `runsc`** as the OCI runtime. A small **Swift** program on macOS uses **Virtualization.framework** to boot the VM. Every runtime blob lives under [`artifacts/`](artifacts/) in this repository (nothing under `$HOME`).

## Architecture

```
macOS host
└── microvm (Virtualization.framework)
    ├── artifacts/Image              (uncompressed arm64 Linux kernel)
    ├── artifacts/initramfs.cpio.zst (u-root + runsc + boot script, zstd-compressed)
    ├── virtio-console ↔ terminal    (hvc0)
    ├── virtio-fs "bundle" ↔ artifacts/bundle
    └── virtio-net (NAT)
        Linux guest
        └── u-root init → gosh /etc/boot.sh → runsc run demo
```

The launcher boots `initramfs.cpio.zst` when present and falls back to `initramfs.cpio` (prints which one to stderr).

Success: console shows kernel boot, u-root, **`gVisor alive`**, then an interactive `/bin/sh` inside gVisor. In that shell, `dmesg` shows gVisor messages, not the VM kernel’s. Exiting the shell powers the VM off and the launcher exits cleanly.

## Prerequisites

| Tool | Purpose |
|------|---------|
| **macOS 13+**, Apple Silicon | Virtualization.framework arm64 Linux boot |
| **Xcode / swift** 5.9+ | Build `microvm` |
| **Go 1.26+** | Build vendored `u-root` (see `vendor/u-root/go.mod`) |
| **podman** | Build guest kernel in Linux container |
| **zstd** | Compress initramfs (`brew install zstd`) |
| **crane** (optional until bundle step) | `go install github.com/google/go-containerregistry/cmd/crane@latest` |

## Quick start

From the repo root:

```bash
make runsc          # artifacts/runsc
make initramfs      # artifacts/initramfs.cpio + .zst
make bundle         # artifacts/bundle/rootfs (+ .stamp)
make kernel         # artifacts/Image (slow first run, then incremental; Podman)
make microvm        # build + ad-hoc codesign
make run            # rebuild whatever is stale, then start VM
```

`make all` builds the compressed initramfs (`initramfs.cpio.zst`) and the bundle stamp. `make run` depends on the `Image`, the `.zst`, the bundle stamp, and the `microvm` binary, so only stale or missing pieces rebuild.

### Paths

Scripts resolve the repo via [`scripts/diorama-vm-root.sh`](scripts/diorama-vm-root.sh) or **`DIORAMA_VM_ROOT`**. The Swift launcher uses the same rules: `DIORAMA_VM_ROOT`, then walk parents from the current working directory until `guest/boot.sh` exists.

## Make targets

| Target | Output |
|--------|--------|
| `runsc` | `artifacts/runsc` (`RUNSC_SOURCE=release` downloads the aarch64 release; `RUNSC_SOURCE=build` compiles the gVisor go branch; also `GVISOR_RELEASE=YYYYMMDD.N`) |
| `initramfs` | `artifacts/initramfs.cpio` + `artifacts/initramfs.cpio.zst` |
| `bundle` | `artifacts/bundle/rootfs` + `artifacts/bundle/.stamp` (Alpine arm64) |
| `kernel` | `artifacts/Image` + `artifacts/kernel.config` |
| `microvm` | `microvm/.build/release/microvm` + codesign with `microvm/vm.entitlements` |
| `run` | Rebuild stale deps, then launch VM |
| `sizes` | `ls -lh` of the boot artifacts plus the `Image` + `.zst` total |
| `clean-artifacts` | Remove large blobs under `artifacts/` (including `.zst`, `kernel.config`, `runsc.sha256`, `.tools`) |

Force a rebuild of anything with `make -B <target>`, e.g. `make -B bundle`.

## Guest boot ([`guest/boot.sh`](guest/boot.sh))

1. Mount virtio-fs share at `/bundle`
2. Bring up `eth0` with `dhclient`
3. Smoke test: `runsc … do echo "gVisor alive"`
4. `runsc … run demo` using the OCI bundle (generates `config.json` via `runsc spec` if missing)
5. When the container exits, print `container exited ($?); powering off` and `shutdown halt` so VZ fires `guestDidStop` (comment that line out to drop to a debug shell instead)

gVisor flags for this MVP:

- `--ignore-cgroups` — no cgroup hierarchy in the throwaway VM
- `--network=host` — container uses the guest network stack
- `--overlay2=root:memory` — container writes stay in RAM (not on the virtio-fs share)

For debugging, add to `boot.sh`: `--debug --debug-log=/tmp/runsc/ --strace`.

## Kernel build (Podman)

[`scripts/build-kernel.sh`](scripts/build-kernel.sh) builds the toolchain-only [`kernel/Dockerfile`](kernel/Dockerfile) and runs [`kernel/build-in-container.sh`](kernel/build-in-container.sh) with the Linux source + objects persisted in the named volume `${DIORAMA_VM_KERNEL_VOLUME:-diorama-vm-linux-src}`, so config tweaks recompile incrementally. The container starts from `make ARCH=arm64 tinyconfig`, merges [`kernel/config-go-arm64.txt`](kernel/config-go-arm64.txt), [`kernel/config-vz-arm64.txt`](kernel/config-vz-arm64.txt), and [`kernel/config-fragment`](kernel/config-fragment), runs `olddefconfig`, then builds an **uncompressed** `arch/arm64/boot/Image` copied to `artifacts/Image` with the final `.config` saved as `artifacts/kernel.config`.

**`VZLinuxBootLoader` requires an uncompressed `Image`, not `Image.gz`.**

Knobs:

- `LINUX_REF` (default `master`), `LINUX_REPO`, `JOBS` — passed into the container; changing ref re-clones.
- `DIORAMA_VM_KERNEL_CLEAN=1` — wipe the volume and start over.
- `DIORAMA_VM_KERNEL_IMAGE` — override the toolchain image tag.
- Podman Machine bind-mount note: only paths under `$HOME` are shared, so `build-kernel.sh` stages `Image`/`kernel.config` via `${DIORAMA_VM_PODMAN_OUT:-${HOME}/.cache/diorama-vm-kernel-out}`.

Kconfig silently drops requested `CONFIG_X=y` lines whose dependencies are unmet or whose symbols were removed. The build prints a loud `WARNING` listing any dropped options — check it after `make kernel`, and compare against `artifacts/kernel.config` when debugging.

## OCI bundle

`make bundle` exports **`busybox:1.36`** for `linux/arm64` into `artifacts/bundle/rootfs` (~4 MiB vs a full Alpine). Override with `DIORAMA_VM_BUNDLE_IMAGE=alpine:latest` if you need apk. Drop in your own `artifacts/bundle/config.json` or let the boot script run `runsc spec`.

The initramfs lists only the u-root commands required for [`guest/boot.sh`](guest/boot.sh) ([`guest/u-root-cmds.txt`](guest/u-root-cmds.txt)), not the full `core` bundle. The guest kernel is built from **`tinyconfig`** plus [`kernel/config-go-arm64.txt`](kernel/config-go-arm64.txt), [`kernel/config-vz-arm64.txt`](kernel/config-vz-arm64.txt), and [`kernel/config-fragment`](kernel/config-fragment), not `defconfig`.

**APFS** is often case-insensitive; some images break on that layout. If you hit odd path errors, use a case-sensitive volume for `artifacts/bundle` or switch to a virtio block device with ext4 (future work).

## Run the launcher manually

```bash
cd microvm
swift build -c release
codesign --force --entitlements vm.entitlements -s - .build/release/microvm
cd ..
DIORAMA_VM_ROOT="$(pwd)" microvm/.build/release/microvm
```

## Verification checklist

1. `artifacts/` contains `Image`, `kernel.config`, `initramfs.cpio` + `initramfs.cpio.zst`, `runsc`, and `bundle/` (with `rootfs/`)
2. `make initramfs` succeeds on macOS (cross-compiles with `GOOS=linux GOARCH=arm64`)
3. `make kernel` succeeds with Podman and the dropped-option WARNING list is empty or expected
4. VM boots; console prints **`gVisor alive`** and which initrd was used
5. Container shell works; `dmesg` inside the container is gVisor’s
6. `exit` powers the VM off and the launcher returns to the prompt

## Troubleshooting

| Symptom | Likely cause |
|---------|----------------|
| `VZLinuxBootLoader` rejects kernel | Compressed kernel — use uncompressed `Image` from `make kernel` |
| Hang after boot, no login/output | Wrong console — need `console=hvc0` and `CONFIG_VIRTIO_CONSOLE` |
| Boot hangs or Go panics early after a kernel change | Missing kernel options — check the WARNING list from `make kernel` and `artifacts/kernel.config` |
| runsc seccomp / namespace errors | Missing kernel options — re-check `kernel/config-fragment` + `config-go-arm64.txt`; run smoke test in `boot.sh` |
| `start failed` / permissions | Sign with [`microvm/vm.entitlements`](microvm/vm.entitlements) (`com.apple.security.virtualization`) |
| `missing … artifacts/…` from Swift | Run the corresponding `make` target; set `DIORAMA_VM_ROOT` if not run from the repo |

## Next steps (out of MVP scope)

- Nested KVM + `runsc --platform=kvm` on supported Apple hardware
- vsock control agent from Swift
- gVisor sandbox networking (netns + veth; drop `--network=host`)
- Trim u-root command set for faster boot

## Repository layout

| Path | Role |
|------|------|
| `artifacts/` | Gitignored VM inputs (tracked `.gitkeep` only) |
| `guest/boot.sh` | Guest uinit script |
| `scripts/` | fetch runsc, initramfs, bundle, kernel |
| `kernel/` | Toolchain Dockerfile + in-container build + Kconfig fragments |
| `microvm/` | Swift VZ launcher |
| `vendor/u-root/` | Vendored u-root; bump intentionally |
