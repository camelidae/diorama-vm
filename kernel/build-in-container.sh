#!/bin/sh
# Runs inside the kernel toolchain container.
#   /src  named volume holding the Linux tree + build objects (persists)
#   /cfg  Kconfig fragments (baked into the image)
#   /out  Image + final .config are copied here
set -eu

REPO="${LINUX_REPO:-https://git.kernel.org/pub/scm/linux/kernel/git/stable/linux.git}"
REF="${LINUX_REF:-master}"
SRC=/src/linux
FRAGS="/cfg/config-go-arm64.txt /cfg/config-vz-arm64.txt /cfg/config-fragment /cfg/config-containerd.txt"

# (Re)clone when the tree is missing or LINUX_REF changed.
if [ ! -d "$SRC/.git" ] || [ "$(cat /src/.ref 2>/dev/null)" != "$REPO@$REF" ]; then
  rm -rf "$SRC"
  git clone --depth 1 --branch "$REF" "$REPO" "$SRC"
  echo "$REPO@$REF" > /src/.ref
fi
cd "$SRC"

# Start from tinyconfig (everything off), layer the fragments on top.
make ARCH=arm64 tinyconfig
./scripts/kconfig/merge_config.sh -m .config $FRAGS
make ARCH=arm64 olddefconfig

# Kconfig silently drops options whose dependencies aren't met or that no
# longer exist. Surface those instead of discovering them at boot.
grep -hE '^CONFIG_[A-Za-z0-9_]+=y$' $FRAGS | sort -u > /tmp/want
grep -E '=y$' .config | sort -u > /tmp/have
comm -23 /tmp/want /tmp/have > /tmp/missing
if [ -s /tmp/missing ]; then
  echo "=================================================================="
  echo "WARNING: requested options NOT set in final .config"
  echo "(unmet dependency, or symbol removed in this kernel version):"
  sed 's/^/  /' /tmp/missing
  echo "=================================================================="
fi

make ARCH=arm64 -j"${JOBS:-$(nproc)}" Image

cp -f arch/arm64/boot/Image /out/Image
cp -f .config /out/kernel.config
ls -lh /out/Image
