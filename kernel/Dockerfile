# Toolchain-only image for building the arm64 guest kernel.
# The Linux source tree lives in a named volume (see scripts/build-kernel.sh),
# so config changes recompile only what changed instead of the whole kernel.
FROM docker.io/library/debian:bookworm-slim
RUN apt-get update && apt-get install -y --no-install-recommends \
    bc \
    bison \
    build-essential \
    ca-certificates \
    cpio \
    flex \
    git \
    libelf-dev \
    libssl-dev \
    rsync \
    && rm -rf /var/lib/apt/lists/*

# Config fragments are baked in (cheap layer) because Podman Machine on macOS
# can only bind-mount paths under $HOME, and the repo may live elsewhere.
COPY config-go-arm64.txt config-vz-arm64.txt config-fragment config-containerd.txt /cfg/
COPY build-in-container.sh /usr/local/bin/build-kernel
RUN chmod +x /usr/local/bin/build-kernel

VOLUME ["/src", "/out"]
ENTRYPOINT ["/usr/local/bin/build-kernel"]
