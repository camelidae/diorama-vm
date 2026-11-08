.PHONY: all runsc initramfs bundle kernel microvm run sizes clean-artifacts help

DIOS_ROOT := $(shell bash scripts/dios-root.sh)
export DIOS_ROOT

ARTIFACTS   := $(DIOS_ROOT)/artifacts
MICROVM_BIN := $(DIOS_ROOT)/microvm/.build/release/microvm

# Where runsc comes from: "release" (prebuilt, already stripped) or "build"
# (gVisor go branch, built with -trimpath -ldflags="-s -w").
RUNSC_SOURCE ?= release

RUNSC  := $(ARTIFACTS)/runsc
CPIO   := $(ARTIFACTS)/initramfs.cpio
INITRD := $(ARTIFACTS)/initramfs.cpio.zst
KERNEL := $(ARTIFACTS)/Image
BUNDLE := $(ARTIFACTS)/bundle/.stamp
DISK   := $(ARTIFACTS)/disk.img

KERNEL_INPUTS  := $(wildcard kernel/*) scripts/build-kernel.sh
MICROVM_INPUTS := $(wildcard microvm/Sources/microvm/*.swift) microvm/Package.swift microvm/vm.entitlements

all: $(INITRD) $(BUNDLE)

help:
	@echo "dios microvm targets (real file targets: only stale/missing pieces rebuild):"
	@echo "  make runsc      - linux/arm64 runsc (RUNSC_SOURCE=release|build)"
	@echo "  make initramfs  - u-root cpio + zstd-compressed initramfs.cpio.zst"
	@echo "  make bundle     - OCI rootfs for artifacts/bundle"
	@echo "  make disk       - 8G sparse ext4 for /var/lib/containerd (once)"
	@echo "  make kernel     - guest Image via podman (first run slow, then incremental)"
	@echo "  make microvm    - swift build -c release + codesign"
	@echo "  make run        - build whatever is missing, then launch the VM"
	@echo "  make sizes      - show artifact sizes"
	@echo "  make all        - runsc + initramfs + bundle"
	@echo "Force a rebuild with -B, e.g. 'make -B bundle'."

runsc:     $(RUNSC)
initramfs: $(INITRD)
bundle:    $(BUNDLE)
kernel:    $(KERNEL)
disk:      $(DISK)
microvm:   $(MICROVM_BIN)

$(RUNSC): scripts/fetch-runsc.sh
	bash scripts/fetch-runsc.sh $(if $(filter build,$(RUNSC_SOURCE)),--build,)

$(CPIO): $(RUNSC) guest/boot.sh guest/u-root-cmds.txt scripts/build-initramfs.sh vendor/u-root/go.mod
	bash scripts/build-initramfs.sh

$(INITRD): $(CPIO)
	@command -v zstd >/dev/null || { echo "zstd is required: brew install zstd" >&2; exit 1; }
	zstd -19 -T0 -q -f $< -o $@

$(BUNDLE): scripts/prepare-bundle.sh
	bash scripts/prepare-bundle.sh
	touch $@

# 8 GiB sparse ext4 for /var/lib/containerd. Created once, never
# overwritten: `rm artifacts/disk.img` to start over.
$(DISK):
	@MKFS=""; \
	if command -v mkfs.ext4 >/dev/null 2>&1; then MKFS=mkfs.ext4; \
	elif [ -x /opt/homebrew/opt/e2fsprogs/sbin/mkfs.ext4 ]; then MKFS=/opt/homebrew/opt/e2fsprogs/sbin/mkfs.ext4; \
	else echo "mkfs.ext4 not found (brew install e2fsprogs)" >&2; exit 1; fi; \
	rm -f "$(DISK)" && dd if=/dev/zero "of=$(DISK)" bs=1m count=0 seek=8192 status=none && "$${MKFS}" -q -F "$(DISK)"
	@ls -lh "$(DISK)"

$(KERNEL): $(KERNEL_INPUTS)
	bash scripts/build-kernel.sh

# Build and sign in one recipe so a rebuilt binary is never left unsigned.
$(MICROVM_BIN): $(MICROVM_INPUTS)
	cd microvm && swift build -c release
	codesign --force --entitlements microvm/vm.entitlements -s - $@

run: $(KERNEL) $(INITRD) $(BUNDLE) $(DISK) $(MICROVM_BIN)
	DIOS_ROOT=$(DIOS_ROOT) $(MICROVM_BIN)

sizes:
	@cd $(ARTIFACTS) && ls -lh Image initramfs.cpio initramfs.cpio.zst runsc disk.img 2>/dev/null || true
	@du -sh $(ARTIFACTS)/bundle 2>/dev/null || true
	@printf 'needed to boot: '; du -ch $(KERNEL) $(INITRD) 2>/dev/null | tail -1 | cut -f1

clean-artifacts:
	rm -f $(KERNEL) $(ARTIFACTS)/kernel.config $(CPIO) $(INITRD) $(RUNSC) $(RUNSC).sha256
	rm -rf $(ARTIFACTS)/bundle $(ARTIFACTS)/.tools
