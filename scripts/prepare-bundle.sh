#!/usr/bin/env bash
set -euo pipefail

DIOS_ROOT="$(bash "$(dirname "$0")/dios-root.sh")"
BUNDLE="${DIOS_ROOT}/artifacts/bundle"
ROOTFS="${BUNDLE}/rootfs"

if ! command -v crane &>/dev/null; then
  echo "crane not on PATH; install with:" >&2
  echo "  go install github.com/google/go-containerregistry/cmd/crane@latest" >&2
  exit 1
fi

rm -rf "${ROOTFS}"
mkdir -p "${ROOTFS}"

# Avoid broken desktop credential helpers when crane pulls public images.
if [[ -z "${DOCKER_CONFIG:-}" ]] && ! docker-credential-desktop version &>/dev/null; then
  _nocreds="$(mktemp -d)"
  trap 'rm -rf "${_nocreds}"' EXIT
  export DOCKER_CONFIG="${_nocreds}"
  printf '%s\n' '{"auths":{}}' >"${DOCKER_CONFIG}/config.json"
fi

BUNDLE_IMAGE="${DIOS_BUNDLE_IMAGE:-busybox:1.36}"
crane export --platform linux/arm64 "${BUNDLE_IMAGE}" - | tar -x -C "${ROOTFS}"

echo "OCI rootfs (${BUNDLE_IMAGE}) -> ${ROOTFS}"
echo "config.json: add your own or let guest boot.sh run 'runsc spec'"
