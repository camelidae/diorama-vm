#!/usr/bin/env bash
# Build the guest kernel in Podman. The Linux tree + objects persist in the
# named volume $DIORAMA_VM_KERNEL_VOLUME, so after the first build a config
# change recompiles only what it touches.
#   LINUX_REF=linux-6.12.y        pick a branch/tag (re-clones when it changes)
#   DIORAMA_VM_KERNEL_CLEAN=1     wipe the volume and start over
set -euo pipefail
DIORAMA_VM_ROOT="$(bash "$(dirname "$0")/diorama-vm-root.sh")"
ARTIFACTS="${DIORAMA_VM_ROOT}/artifacts"
KERNEL_DIR="${DIORAMA_VM_ROOT}/kernel"
OUT="${ARTIFACTS}/Image"
IMAGE_TAG="${DIORAMA_VM_KERNEL_IMAGE:-diorama-vm-guest-kernel:latest}"
VOLUME="${DIORAMA_VM_KERNEL_VOLUME:-diorama-vm-linux-src}"

if ! command -v podman &>/dev/null; then
  echo "podman is required to build the guest kernel" >&2
  exit 1
fi
mkdir -p "${ARTIFACTS}"

if [[ "${DIORAMA_VM_KERNEL_CLEAN:-0}" == "1" ]]; then
  podman volume rm -f "${VOLUME}" >/dev/null 2>&1 || true
fi

podman build -t "${IMAGE_TAG}" -f "${KERNEL_DIR}/Dockerfile" "${KERNEL_DIR}"

# Podman Machine on macOS only bind-mounts paths under the user home directory.
PODMAN_OUT="${DIORAMA_VM_PODMAN_OUT:-${HOME}/.cache/diorama-vm-kernel-out}"
mkdir -p "${PODMAN_OUT}"

podman run --rm \
  -v "${VOLUME}:/src" \
  -v "${PODMAN_OUT}:/out:Z" \
  -e LINUX_REF="${LINUX_REF:-master}" \
  ${LINUX_REPO:+-e LINUX_REPO="${LINUX_REPO}"} \
  ${JOBS:+-e JOBS="${JOBS}"} \
  "${IMAGE_TAG}"

cp -f "${PODMAN_OUT}/Image" "${OUT}"
cp -f "${PODMAN_OUT}/kernel.config" "${ARTIFACTS}/kernel.config"
echo "kernel Image -> ${OUT} ($(du -h "${OUT}" | cut -f1)); config -> ${ARTIFACTS}/kernel.config"
