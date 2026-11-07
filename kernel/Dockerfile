# Build uncompressed arm64 Image for VZLinuxBootLoader.
FROM docker.io/library/debian:bookworm-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
    bc \
    bison \
    build-essential \
    cpio \
    flex \
    libelf-dev \
    libssl-dev \
    rsync \
    wget \
    ca-certificates \
    git \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /build

ARG LINUX_REF=master
RUN git clone --depth 1 --branch "${LINUX_REF}" \
    https://git.kernel.org/pub/scm/linux/kernel/git/stable/linux.git linux

WORKDIR /build/linux

COPY config-fragment /build/config-fragment
COPY config-go-arm64.txt /build/config-go-arm64.txt
COPY config-vz-arm64.txt /build/config-vz-arm64.txt

# Trimmed defconfig: full arm64 base (needed for Virtualization.framework) with virtio/seccomp
# fragments and common debug noise turned off.
RUN make ARCH=arm64 defconfig && \
    cat /build/config-go-arm64.txt /build/config-vz-arm64.txt /build/config-fragment >> .config && \
    ./scripts/config -d DEBUG_KERNEL && \
    ./scripts/config -d DEBUG_INFO && \
    ./scripts/config -d KALLSYMS && \
    ./scripts/config -d KALLSYMS_ALL && \
    ./scripts/config --set-str CONFIG_LOCALVERSION "" && \
    make ARCH=arm64 olddefconfig && \
    make ARCH=arm64 -j"$(nproc)" Image

# Default artifact path inside the container
VOLUME /out
CMD cp -f arch/arm64/boot/Image /out/Image
