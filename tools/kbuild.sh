#!/bin/sh
# Runs inside the fp6-kernel-kbuild container (alpine:edge x86_64, clang 23).
# usage: kbuild.sh <make targets...>
set -e
cd /work/milos-linux
M="make ARCH=arm64 LLVM=1 O=/work/kbuild LOCALVERSION= -j$(nproc)"
if [ ! -f /work/kbuild/.config ]; then
	mkdir -p /work/kbuild
	cp /work/boot/config-phone /work/kbuild/.config
	./scripts/config --file /work/kbuild/.config -m VIDEO_CCS
	$M olddefconfig
fi
exec $M KCFLAGS="-march=armv8.6-a+fp16fml+aes+sha3+sm4 -mtune=cortex-a720" "$@"
