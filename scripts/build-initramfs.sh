#!/usr/bin/env bash
set -euo pipefail
DIOS_ROOT="$(bash "$(dirname "$0")/dios-root.sh")"
ARTIFACTS="${DIOS_ROOT}/artifacts"
UROOT="${DIOS_ROOT}/vendor/u-root"
RUNSC="${ARTIFACTS}/runsc"
OUT="${ARTIFACTS}/initramfs.cpio"
TOOLS="${ARTIFACTS}/.tools"

if [[ ! -x "${RUNSC}" ]]; then
  echo "missing executable ${RUNSC} — run: make runsc" >&2
  exit 1
fi

# Build the u-root tool from the vendored pin into artifacts/.tools instead of
# `go install`, so it never clobbers (or is clobbered by) a global
# $GOPATH/bin/u-root from another version.
mkdir -p "${TOOLS}"
(cd "${UROOT}" && go build -o "${TOOLS}/u-root" .)
UROOT_BIN="${TOOLS}/u-root"

# The cmds/ wrappers (containerd-shim-runsc-v1, dios-vsockd) live outside
# vendor/u-root, so they build through the pinned workspace. fetch-src.sh
# owns ${ARTIFACTS}/.src/go.work; ensure our module is used from it.
WORK="${ARTIFACTS}/.src/go.work"
GO_MOD_FLAG=()
if [[ -f "${WORK}" ]]; then
  if ! grep -q "dios/cmds" "${WORK}"; then
    (cd "${ARTIFACTS}/.src" && go work use "${DIOS_ROOT}/cmds")
  fi
  export GOWORK="${WORK}"
  # containerd needs these to build without system libs / docs deps.
  export GOFLAGS="-tags=no_btrfs,no_devmapper,no_zfs,urfave_cli_no_docs"
  # u-root defaults to -mod=vendor (vendor/ exists), which in workspace
  # mode demands a vendor/ tree next to go.work ("inconsistent vendoring").
  # readonly builds from the module graph instead.
  GO_MOD_FLAG=(-go-mod=readonly)
fi

UROOT_CMDS=()
while IFS= read -r line || [[ -n "$line" ]]; do
  line="${line%%#*}"
  line="${line#"${line%%[![:space:]]*}"}"
  line="${line%"${line##*[![:space:]]}"}"
  [[ -z "$line" ]] && continue
  UROOT_CMDS+=("$line")
done < "${DIOS_ROOT}/guest/u-root-cmds.txt"

cd "${UROOT}"
FILES_ARGS=(
  -files "${RUNSC}:bin/runsc"
  -files "${DIOS_ROOT}/guest/boot.sh:etc/boot.sh"
  -files "${DIOS_ROOT}/guest/containerd-config.toml:etc/containerd/config.toml"
  -files "${DIOS_ROOT}/guest/runsc-options.toml:etc/containerd/runsc/config.toml"
)
# Guest TLS (ctr pull) needs a CA bundle; macOS hosts always carry one.
if [[ -f /etc/ssl/cert.pem ]]; then
  FILES_ARGS+=(-files "/etc/ssl/cert.pem:etc/ssl/certs/ca-certificates.crt")
fi
GOOS=linux GOARCH=arm64 "${UROOT_BIN}" \
  "${GO_MOD_FLAG[@]}" \
  -o "${OUT}" \
  "${FILES_ARGS[@]}" \
  -uinitcmd="gosh /etc/boot.sh" \
  "${UROOT_CMDS[@]}"
echo "initramfs -> ${OUT} ($(du -h "${OUT}" | cut -f1))"
