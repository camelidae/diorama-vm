.PHONY: all runsc initramfs bundle kernel microvm run clean-artifacts help

DIOS_ROOT := $(shell bash scripts/dios-root.sh)
export DIOS_ROOT

ARTIFACTS := $(DIOS_ROOT)/artifacts
MICROVM_BIN := $(DIOS_ROOT)/microvm/.build/release/microvm

all: runsc initramfs bundle

help:
	@echo "dios microvm targets:"
	@echo "  make runsc      - fetch linux/arm64 runsc into artifacts/"
	@echo "  make initramfs  - build u-root cpio (needs runsc)"
	@echo "  make bundle     - OCI rootfs for artifacts/bundle"
	@echo "  make kernel     - build guest Image via podman (slow)"
	@echo "  make microvm    - swift build -c release + codesign"
	@echo "  make run        - launch VM (needs all artifacts + microvm)"
	@echo "  make all        - runsc + initramfs + bundle"

runsc:
	bash scripts/fetch-runsc.sh

initramfs: runsc
	bash scripts/build-initramfs.sh

bundle:
	bash scripts/prepare-bundle.sh

kernel:
	bash scripts/build-kernel.sh

microvm:
	cd microvm && swift build -c release
	codesign --force --entitlements vm.entitlements -s - $(MICROVM_BIN)

run: microvm
	@test -f $(ARTIFACTS)/Image || (echo "missing $(ARTIFACTS)/Image — run: make kernel" >&2; exit 1)
	@test -f $(ARTIFACTS)/initramfs.cpio || (echo "missing initramfs — run: make initramfs" >&2; exit 1)
	DIOS_ROOT=$(DIOS_ROOT) $(MICROVM_BIN)

clean-artifacts:
	rm -f $(ARTIFACTS)/Image $(ARTIFACTS)/initramfs.cpio $(ARTIFACTS)/runsc
	rm -rf $(ARTIFACTS)/bundle
