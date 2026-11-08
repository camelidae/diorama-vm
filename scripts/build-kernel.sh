#!/usr/bin/env bash
# Build the guest kernel in a container. The Linux tree + objects persist in the
# named volume $DIORAMA_VM_KERNEL_VOLUME, so after the first build a config
# change recompiles only what it touches.
#   LINUX_REF=linux-6.12.y        pick a branch/tag (re-clones when it changes)
#   DIORAMA_VM_KERNEL_CLEAN=1     wipe the volume and start over
#   CONTAINER_ENGINE=podman|docker  (default: podman if present, else docker)
set -euo pipefail
DIORAMA_VM_ROOT="$(bash "$(dirname "$0")/diorama-vm-root.sh")"
ARTIFACTS="${DIORAMA_VM_ROOT}/artifacts"
KERNEL_DIR="${DIORAMA_VM_ROOT}/kernel"
OUT="${ARTIFACTS}/Image"
IMAGE_TAG="${DIORAMA_VM_KERNEL_IMAGE:-diorama-vm-guest-kernel:latest}"
VOLUME="${DIORAMA_VM_KERNEL_VOLUME:-diorama-vm-linux-src}"

if [[ -n "${CONTAINER_ENGINE:-}" ]]; then
  ENGINE="${CONTAINER_ENGINE}"
elif command -v podman &>/dev/null; then
  ENGINE=podman
elif command -v docker &>/dev/null; then
  ENGINE=docker
else
  echo "podman or docker is required to build the guest kernel" >&2
  exit 1
fi
if ! command -v "${ENGINE}" &>/dev/null; then
  echo "CONTAINER_ENGINE=${ENGINE} not found on PATH" >&2
  exit 1
fi
mkdir -p "${ARTIFACTS}"

# Prefer a host directory (CI cache-friendly) when DIORAMA_VM_KERNEL_SRC is set;
# otherwise use a named container volume for incremental local builds.
if [[ -n "${DIORAMA_VM_KERNEL_SRC:-}" ]]; then
  mkdir -p "${DIORAMA_VM_KERNEL_SRC}"
  if [[ "${DIORAMA_VM_KERNEL_CLEAN:-0}" == "1" ]]; then
    rm -rf "${DIORAMA_VM_KERNEL_SRC:?}/"*
  fi
  SRC_MOUNT="${DIORAMA_VM_KERNEL_SRC}:/src"
else
  if [[ "${DIORAMA_VM_KERNEL_CLEAN:-0}" == "1" ]]; then
    "${ENGINE}" volume rm -f "${VOLUME}" >/dev/null 2>&1 || true
  fi
  "${ENGINE}" volume create "${VOLUME}" >/dev/null 2>&1 || true
  SRC_MOUNT="${VOLUME}:/src"
fi

"${ENGINE}" build -t "${IMAGE_TAG}" -f "${KERNEL_DIR}/Dockerfile" "${KERNEL_DIR}"

# Podman Machine on macOS only bind-mounts paths under the user home directory.
PODMAN_OUT="${DIORAMA_VM_PODMAN_OUT:-${HOME}/.cache/diorama-vm-kernel-out}"
mkdir -p "${PODMAN_OUT}"

OUT_MOUNT="${PODMAN_OUT}:/out"
if [[ "${ENGINE}" == "podman" ]]; then
  OUT_MOUNT="${PODMAN_OUT}:/out:Z"
  case "${SRC_MOUNT}" in
    *:/*) SRC_MOUNT="${SRC_MOUNT}:Z" ;;
  esac
fi

"${ENGINE}" run --rm \
  -v "${SRC_MOUNT}" \
  -v "${OUT_MOUNT}" \
  -e LINUX_REF="${LINUX_REF:-master}" \
  ${LINUX_REPO:+-e LINUX_REPO="${LINUX_REPO}"} \
  ${JOBS:+-e JOBS="${JOBS}"} \
  "${IMAGE_TAG}"

cp -f "${PODMAN_OUT}/Image" "${OUT}"
cp -f "${PODMAN_OUT}/kernel.config" "${ARTIFACTS}/kernel.config"
echo "kernel Image -> ${OUT} ($(du -h "${OUT}" | cut -f1)); config -> ${ARTIFACTS}/kernel.config"
