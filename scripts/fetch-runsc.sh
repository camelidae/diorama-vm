#!/usr/bin/env bash
set -euo pipefail

DIOS_ROOT="$(bash "$(dirname "$0")/dios-root.sh")"
ARTIFACTS="${DIOS_ROOT}/artifacts"
OUT="${ARTIFACTS}/runsc"
BUILD=0

usage() {
  echo "usage: $0 [--build]" >&2
  echo "  default: download gVisor release runsc (linux/arm64)" >&2
  echo "  --build: compile from gVisor go branch" >&2
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --build) BUILD=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown option: $1" >&2; usage; exit 1 ;;
  esac
done

mkdir -p "${ARTIFACTS}"

if [[ "${BUILD}" -eq 1 ]]; then
  tmp="$(mktemp -d)"
  trap 'rm -rf "${tmp}"' EXIT
  git clone --depth 1 -b go https://github.com/google/gvisor.git "${tmp}/gvisor"
  (
    cd "${tmp}/gvisor"
    CGO_ENABLED=0 GOOS=linux GOARCH=arm64 go build -o "${OUT}" ./runsc
  )
else
  default_release="20250106.0"
  release="${GVISOR_RELEASE:-}"
  if [[ -z "${release}" ]]; then
    tag="$(curl -fsSL "https://api.github.com/repos/google/gvisor/releases/latest" \
      | sed -n 's/.*"tag_name"[[:space:]]*:[[:space:]]*"release-\([^"]*\)".*/\1/p' \
      | head -1)"
  else
    tag="${release}"
  fi

  try_download() {
    local ver="$1"
    local url="https://storage.googleapis.com/gvisor/releases/release/${ver}/aarch64/runsc"
    if curl -fsSL -o "${OUT}" "${url}"; then
      echo "gVisor release ${ver}"
      return 0
    fi
    return 1
  }

  if [[ -n "${tag}" ]] && try_download "${tag}"; then
    :
  elif [[ -z "${GVISOR_RELEASE:-}" ]] && [[ "${tag}" != "${default_release}" ]] && try_download "${default_release}"; then
    echo "note: latest GitHub release has no aarch64 blob; using pinned ${default_release}" >&2
  else
    echo "download failed; set GVISOR_RELEASE=YYYYMMDD.N or use --build" >&2
    exit 1
  fi
fi

chmod +x "${OUT}"
if command -v shasum &>/dev/null; then
  shasum -a 256 "${OUT}" | tee "${OUT}.sha256"
fi
echo "runsc -> ${OUT}"
