# dios

Apple Silicon micro-VM whose guest userland is a **u-root** initramfs with **gVisor `runsc`** as the OCI runtime. A small **Swift** program on macOS uses **Virtualization.framework** to boot the VM. Every runtime blob lives under [`artifacts/`](artifacts/) in this repository (nothing under `$HOME`).

## Architecture

```
macOS host
└── microvm (Virtualization.framework)
    ├── artifacts/Image              (uncompressed arm64 Linux kernel)
    ├── artifacts/initramfs.cpio     (u-root + runsc + boot script)
    ├── virtio-console ↔ terminal    (hvc0)
    ├── virtio-fs "bundle" ↔ artifacts/bundle
    └── virtio-net (NAT)
        Linux guest
        └── u-root init → gosh /etc/boot.sh → runsc run demo
```

Success: console shows kernel boot, u-root, **`gVisor alive`**, then an interactive `/bin/sh` inside gVisor. In that shell, `dmesg` shows gVisor messages, not the VM kernel’s.

## Prerequisites

| Tool | Purpose |
|------|---------|
| **macOS 13+**, Apple Silicon | Virtualization.framework arm64 Linux boot |
| **Xcode / swift** 5.9+ | Build `microvm` |
| **Go 1.26+** | Build vendored `u-root` (see `vendor/u-root/go.mod`) |
| **podman** | Build guest kernel in Linux container |
| **crane** (optional until bundle step) | `go install github.com/google/go-containerregistry/cmd/crane@latest` |

## Quick start

From the repo root:

```bash
make runsc          # artifacts/runsc
make initramfs      # artifacts/initramfs.cpio
make bundle         # artifacts/bundle/rootfs
make kernel         # artifacts/Image (slow; Podman)
make microvm        # build + ad-hoc codesign
make run            # start VM (needs all of the above)
```

`make all` runs `runsc`, `initramfs`, and `bundle` only (not the kernel or launcher).

### Paths

Scripts resolve the repo via [`scripts/dios-root.sh`](scripts/dios-root.sh) or **`DIOS_ROOT`**. The Swift launcher uses the same rules: `DIOS_ROOT`, then walk parents from the current working directory until `guest/boot.sh` exists.

## Make targets

| Target | Output |
|--------|--------|
| `runsc` | `artifacts/runsc` (download aarch64 release; override with `GVISOR_RELEASE=YYYYMMDD.N` or `scripts/fetch-runsc.sh --build`) |
| `initramfs` | `artifacts/initramfs.cpio` |
| `bundle` | `artifacts/bundle/rootfs` (Alpine arm64) |
| `kernel` | `artifacts/Image` |
| `microvm` | `microvm/.build/release/microvm` + codesign with `vm.entitlements` |
| `run` | Launch VM |
| `clean-artifacts` | Remove large blobs under `artifacts/` |

## Guest boot ([`guest/boot.sh`](guest/boot.sh))

1. Mount virtio-fs share at `/bundle`
2. Bring up `eth0` with `dhclient`
3. Smoke test: `runsc … do echo "gVisor alive"`
4. `runsc … run demo` using the OCI bundle (generates `config.json` via `runsc spec` if missing)

gVisor flags for this MVP:

- `--ignore-cgroups` — no cgroup hierarchy in the throwaway VM
- `--network=host` — container uses the guest network stack
- `--overlay2=root:memory` — container writes stay in RAM (not on the virtio-fs share)

For debugging, add to `boot.sh`: `--debug --debug-log=/tmp/runsc/ --strace`.

## Kernel build (Podman)

[`scripts/build-kernel.sh`](scripts/build-kernel.sh) builds [`kernel/Dockerfile`](kernel/Dockerfile), which clones stable Linux, applies [`kernel/config-fragment`](kernel/config-fragment), and produces an **uncompressed** `arch/arm64/boot/Image` copied to `artifacts/Image`.

**`VZLinuxBootLoader` requires an uncompressed `Image`, not `Image.gz`.**

Override the container tag with `DIOS_KERNEL_IMAGE` if needed.

## OCI bundle

`make bundle` exports **`busybox:1.36`** for `linux/arm64` into `artifacts/bundle/rootfs` (~4 MiB vs a full Alpine). Override with `DIOS_BUNDLE_IMAGE=alpine:latest` if you need apk. Drop in your own `artifacts/bundle/config.json` or let the boot script run `runsc spec`.

The initramfs lists only the u-root commands required for [`guest/boot.sh`](guest/boot.sh) ([`guest/u-root-cmds.txt`](guest/u-root-cmds.txt)), not the full `core` bundle. The guest kernel is built from **`tinyconfig`** plus [`kernel/config-fragment`](kernel/config-fragment) and [`kernel/config-go-arm64.txt`](kernel/config-go-arm64.txt), not `defconfig`.

**APFS** is often case-insensitive; some images break on that layout. If you hit odd path errors, use a case-sensitive volume for `artifacts/bundle` or switch to a virtio block device with ext4 (future work).

## Run the launcher manually

```bash
cd microvm
swift build -c release
codesign --force --entitlements vm.entitlements -s - .build/release/microvm
cd ..
DIOS_ROOT="$(pwd)" microvm/.build/release/microvm
```

## Verification checklist

1. `artifacts/` contains `Image`, `initramfs.cpio`, `runsc`, and `bundle/` (with `rootfs/`)
2. `make initramfs` succeeds on macOS (cross-compiles with `GOOS=linux GOARCH=arm64`)
3. `make kernel` succeeds with Podman
4. VM boots; console prints **`gVisor alive`**
5. Container shell works; `dmesg` inside the container is gVisor’s

## Troubleshooting

| Symptom | Likely cause |
|---------|----------------|
| `VZLinuxBootLoader` rejects kernel | Compressed kernel — use uncompressed `Image` from `make kernel` |
| Hang after boot, no login/output | Wrong console — need `console=hvc0` and `CONFIG_VIRTIO_CONSOLE` |
| runsc seccomp / namespace errors | Missing kernel options — re-check `kernel/config-fragment`; run smoke test in `boot.sh` |
| `start failed` / permissions | Sign with [`microvm/vm.entitlements`](microvm/vm.entitlements) (`com.apple.security.virtualization`) |
| `missing … artifacts/…` from Swift | Run the corresponding `make` target; set `DIOS_ROOT` if not run from the repo |

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
| `kernel/` | Dockerfile + Kconfig fragment |
| `microvm/` | Swift VZ launcher |
| `vendor/u-root/` | Vendored u-root; bump intentionally |

See [AGENTS.md](AGENTS.md) for contributor notes.
