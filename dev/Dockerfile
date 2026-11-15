# Kernel development container for fp6-img on an Apple Silicon Mac (or any
# arm64 host): native aarch64 Alpine, so kernel builds need no cross toolchain
# and no qemu. Used through ../dev.sh; see docs/README.md.
#
# Deliberately has no fastboot or adb: the phone is only ever driven from the
# host (Docker Desktop cannot pass USB through anyway), so there is one place
# that talks to it.
FROM alpine:edge

RUN apk add --no-cache \
	bash bc bison build-base clang coreutils diffutils elfutils-dev findutils flex git \
	linux-headers lld llvm make openssl-dev pahole perl python3 \
	xz zstd \
	android-tools-mkbootimg android-tools-unpack_bootimg

# The kernel tree and build output live in Docker volumes under /work
# (case-sensitive, unlike the default macOS filesystem); the repository is
# bind-mounted at /work/fp6-img and results are copied to /work/fp6-img/out.
WORKDIR /work
