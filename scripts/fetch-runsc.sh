#!/usr/bin/env bash
set -euo pipefail
DIORAMA_VM_ROOT="$(bash "$(dirname "$0")/diorama-vm-root.sh")"
ARTIFACTS="${DIORAMA_VM_ROOT}/artifacts"
OUT="${ARTIFACTS}/runsc"
BUILD=0

usage() {
  echo "usage: $0 [--build]" >&2
  echo "  default: download gVisor release runsc (linux/arm64), verify sha512" >&2
  echo "  --build: compile from gVisor go branch, stripped (GVISOR_REF=go)" >&2
}
while [[ $# -gt 0 ]]; do
  case "$1" in
    --build) BUILD=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown option: $1" >&2; usage; exit 1 ;;
  esac
done

mkdir -p "${ARTIFACTS}"
tmp="$(mktemp -d)"
trap 'rm -rf "${tmp}"' EXIT

if [[ "${BUILD}" -eq 1 ]]; then
  git clone --depth 1 -b "${GVISOR_REF:-go}" https://github.com/google/gvisor.git "${tmp}/gvisor"
  (
    cd "${tmp}/gvisor"
    # go.mod pins the Go version gVisor needs; GOTOOLCHAIN=auto fetches it.
    CGO_ENABLED=0 GOOS=linux GOARCH=arm64 GOTOOLCHAIN=auto go build \
      -trimpath -buildvcs=false -ldflags="-s -w" \
      -o "${tmp}/runsc" ./runsc
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
    local url="https://storage.googleapis.com/gvisor/releases/release/${ver}/aarch64"
    curl -fsSL -o "${tmp}/runsc" "${url}/runsc" || return 1
    if curl -fsSL -o "${tmp}/runsc.sha512" "${url}/runsc.sha512"; then
      (cd "${tmp}" && shasum -a 512 -c runsc.sha512) >&2 || {
        echo "sha512 mismatch for ${ver}" >&2; exit 1; }
    else
      echo "warning: no runsc.sha512 published for ${ver}; skipping verification" >&2
    fi
    echo "gVisor release ${ver}"
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

# Only replace the artifact once we have a complete, verified binary.
# Release blobs ship with debug_info (not stripped); strip here for a free
# size win. llvm-strip handles cross-arch ELF; fall back gracefully.
if command -v llvm-strip &>/dev/null; then
  llvm-strip "${tmp}/runsc" 2>/dev/null || true
else
  # Homebrew installs versioned llvm (llvm@N) without an unversioned link.
  STRIP="$(ls /opt/homebrew/opt/llvm*/bin/llvm-strip /opt/homebrew/Cellar/llvm*/*/bin/llvm-strip 2>/dev/null | head -1 || true)"
  if [[ -n "${STRIP:-}" ]]; then
    "${STRIP}" "${tmp}/runsc" 2>/dev/null || true
  else
    echo "warning: llvm-strip not found; runsc left unstripped (brew install llvm)" >&2
  fi
fi
install -m 0755 "${tmp}/runsc" "${OUT}"
shasum -a 256 "${OUT}" | tee "${OUT}.sha256"
command -v file &>/dev/null && file "${OUT}"
echo "runsc -> ${OUT} ($(du -h "${OUT}" | cut -f1))"
