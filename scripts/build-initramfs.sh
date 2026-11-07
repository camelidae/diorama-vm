#!/usr/bin/env bash
set -euo pipefail

DIOS_ROOT="$(bash "$(dirname "$0")/dios-root.sh")"
ARTIFACTS="${DIOS_ROOT}/artifacts"
UROOT="${DIOS_ROOT}/vendor/u-root"
RUNSC="${ARTIFACTS}/runsc"
OUT="${ARTIFACTS}/initramfs.cpio"

if [[ ! -x "${RUNSC}" ]]; then
  echo "missing executable ${RUNSC} — run: make runsc" >&2
  exit 1
fi

cd "${UROOT}"
go install .

UROOT_BIN="$(go env GOPATH)/bin/u-root"
if [[ ! -x "${UROOT_BIN}" ]]; then
  echo "u-root binary not found at ${UROOT_BIN}" >&2
  exit 1
fi

UROOT_CMDS=()
while IFS= read -r line || [[ -n "$line" ]]; do
  line="${line%%#*}"
  line="${line#"${line%%[![:space:]]*}"}"
  line="${line%"${line##*[![:space:]]}"}"
  [[ -z "$line" ]] && continue
  UROOT_CMDS+=("$line")
done < "${DIOS_ROOT}/guest/u-root-cmds.txt"

GOOS=linux GOARCH=arm64 "${UROOT_BIN}" \
  -o "${OUT}" \
  -files "${RUNSC}:bin/runsc" \
  -files "${DIOS_ROOT}/guest/boot.sh:etc/boot.sh" \
  -uinitcmd="gosh /etc/boot.sh" \
  "${UROOT_CMDS[@]}"

echo "initramfs -> ${OUT}"
