#!/usr/bin/env bash
# Clone pinned u-root, gVisor and containerd into artifacts/.src, apply
# patches/*, and write a go.work linking them with cmds/.
#
# Nothing upstream is committed: third_party/pins records the exact SHAs and
# this script materializes them. u-root is fetched like the others rather than
# vendored in-tree, so its own vendor/ tree (which upstream commits) comes
# along with the clone and offline builds still work.
# No `go work replace` version overrides: the otelgrpc skew is fixed by the
# containerd source patch instead (see patches/containerd/0001-otelgrpc.patch).
set -euo pipefail
DIORAMA_VM_ROOT="$(bash "$(dirname "$0")/diorama-vm-root.sh")"
ARTIFACTS="${DIORAMA_VM_ROOT}/artifacts"
SRC="${ARTIFACTS}/.src"

# shellcheck disable=SC1091
source "${DIORAMA_VM_ROOT}/third_party/pins"

mkdir -p "${SRC}"

clone_or_update() {
  local repo="$1" pin="$2" dest="$3" branch="${4:-}"
  if [[ -d "${dest}/.git" ]]; then
    if [[ -n "${branch}" ]]; then
      git -C "${dest}" fetch --depth 1 origin "${branch}"
    else
      git -C "${dest}" fetch --depth 1 origin HEAD || git -C "${dest}" fetch origin
    fi
    # A raw SHA is not a ref; fetch it directly (GitHub allows SHA fetch).
    git -C "${dest}" rev-parse -q --verify "${pin}^{commit}" >/dev/null 2>&1 \
      || git -C "${dest}" fetch --depth 1 origin "${pin}"
    git -C "${dest}" checkout -f "${pin}"
  else
    if [[ -n "${branch}" ]]; then
      git clone --depth 1 -b "${branch}" "${repo}" "${dest}"
    else
      git clone --depth 1 "${repo}" "${dest}"
    fi
    git -C "${dest}" rev-parse -q --verify "${pin}^{commit}" >/dev/null 2>&1 \
      || git -C "${dest}" fetch --depth 1 origin "${pin}"
    git -C "${dest}" checkout -f "${pin}"
  fi
}

clone_or_update "${UROOT_REPO}" "${UROOT_PIN}" "${SRC}/u-root" "${UROOT_BRANCH:-}"
clone_or_update "${GVISOR_REPO}" "${GVISOR_PIN}" "${SRC}/gvisor" "${GVISOR_BRANCH:-go}"
clone_or_update "${CONTAINERD_REPO}" "${CONTAINERD_PIN}" "${SRC}/containerd" "${CONTAINERD_BRANCH:-}"

# Apply patches (idempotent: skip if already applied).
for p in "${DIORAMA_VM_ROOT}"/patches/containerd/*.patch; do
  if git -C "${SRC}/containerd" apply --reverse --check "${p}" >/dev/null 2>&1; then
    echo "patch already applied: ${p}"
  else
    git -C "${SRC}/containerd" apply --check "${p}" && git -C "${SRC}/containerd" apply "${p}"
    echo "applied: ${p}"
  fi
done
for p in "${DIORAMA_VM_ROOT}"/patches/gvisor/*.patch; do
  if git -C "${SRC}/gvisor" apply --reverse --check "${p}" >/dev/null 2>&1; then
    echo "patch already applied: ${p}"
  else
    git -C "${SRC}/gvisor" apply --check "${p}" && git -C "${SRC}/gvisor" apply "${p}"
    echo "applied: ${p}"
  fi
done

cat > "${SRC}/go.work" <<EOF
go 1.27.3

use (
	${SRC}/u-root
	${DIORAMA_VM_ROOT}/cmds
	${SRC}/gvisor
	${SRC}/containerd
)
EOF
echo "wrote ${SRC}/go.work"
git -C "${SRC}/u-root" rev-parse HEAD
git -C "${SRC}/gvisor" rev-parse HEAD
git -C "${SRC}/containerd" rev-parse HEAD
