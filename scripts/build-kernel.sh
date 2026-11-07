#!/usr/bin/env bash
set -euo pipefail

DIOS_ROOT="$(bash "$(dirname "$0")/dios-root.sh")"
ARTIFACTS="${DIOS_ROOT}/artifacts"
KERNEL_DIR="${DIOS_ROOT}/kernel"
OUT="${ARTIFACTS}/Image"
IMAGE_TAG="${DIOS_KERNEL_IMAGE:-dios-guest-kernel:latest}"

if ! command -v podman &>/dev/null; then
  echo "podman is required to build the guest kernel" >&2
  exit 1
fi

mkdir -p "${ARTIFACTS}"

podman build -t "${IMAGE_TAG}" -f "${KERNEL_DIR}/Dockerfile" "${KERNEL_DIR}"

# Podman Machine on macOS only bind-mounts paths under the user home directory.
PODMAN_OUT="${DIOS_PODMAN_OUT:-${HOME}/.cache/dios-kernel-out}"
mkdir -p "${PODMAN_OUT}"

podman run --rm \
  -v "${PODMAN_OUT}:/out:Z" \
  "${IMAGE_TAG}"

if [[ "${PODMAN_OUT}/Image" != "${OUT}" ]]; then
  cp -f "${PODMAN_OUT}/Image" "${OUT}"
fi

if [[ ! -f "${OUT}" ]]; then
  echo "expected ${OUT} after podman run" >&2
  exit 1
fi

echo "kernel Image -> ${OUT}"
