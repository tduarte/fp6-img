#!/bin/sh
# Kernel development loop on macOS (or any host with Docker): build the
# patched kernel in a container, copy the results to out/, then drive the
# phone from the host with tools/cycle.sh.
#
#   ./dev.sh image             build the container image (fp6-dev)
#   ./dev.sh src               fetch KERNEL_COMMIT (from build.sh) into the
#                              fp6-milos-linux volume and apply the aport's
#                              000*.patch queue as git commits
#   ./dev.sh kbuild [targets]  make in the tree with the aport config
#                              (default: Image.gz dtbs modules), then copy
#                              Image.gz, the FP6 dtb and the camera modules
#                              to out/
#   ./dev.sh patches           write the tree's commits on top of
#                              KERNEL_COMMIT back to the aport as 000*.patch
#   ./dev.sh bootimg <boot.img> [out.img]
#                              RAM-boot test image: <boot.img>'s kernel and
#                              ramdisk with out/'s dtb (tools/mk-test-bootimg.sh)
#   ./dev.sh shell             interactive shell in the container
#
# Nothing here talks to the phone. Never `fastboot flash boot` on the FP6: the
# bootloader then wipes the modem NV. Use `fastboot boot` (tools/cycle.sh).
set -eu
cd "$(dirname "$0")"

IMAGE=fp6-dev
KAPORT=aports/device/linux-postmarketos-qcom-milos
KERNEL_REPO=$(sed -n 's/^KERNEL_REPO=//p' build.sh)
KERNEL_COMMIT=${KERNEL_COMMIT:-$(sed -n 's/^KERNEL_COMMIT=\${KERNEL_COMMIT-\([0-9a-f]*\)}$/\1/p' build.sh)}
DTB=qcom/milos-fairphone-fp6.dtb

# The container runs as root. Docker Desktop (macOS) maps files it writes into
# the bind-mounted repository back to the host user; Docker on Linux does not,
# so on exit hand anything root-owned under out/ and aports/ back to the
# caller (a no-op on macOS, and under rootless Podman, where root is the caller).
run() {
	docker run --rm $TTY \
		-v fp6-milos-linux:/work/milos-linux \
		-v fp6-kbuild:/work/kbuild \
		-v "$PWD":/work/fp6-img \
		-e KERNEL_REPO="$KERNEL_REPO" -e KERNEL_COMMIT="$KERNEL_COMMIT" \
		-e DTB="$DTB" -e KAPORT="$KAPORT" -e HOST_IDS="$(id -u):$(id -g)" \
		"$IMAGE" sh -euc '
		trap "[ \"\$HOST_IDS\" = 0:0 ] || find /work/fp6-img/out /work/fp6-img/aports \
			-user 0 -exec chown \"\$HOST_IDS\" {} + 2>/dev/null || true" EXIT
		'"$1"
}
TTY=
[ -t 0 ] && TTY=-it

[ $# -ge 1 ] || { sed -n '2,24p' "$0"; exit 1; }
cmd=$1; shift
case "$cmd" in
image)
	docker build -t "$IMAGE" dev
	;;
src)
	run '
	cd /work/milos-linux
	git config --global user.name fp6-dev; git config --global user.email fp6-dev@localhost
	git config --global --add safe.directory /work/milos-linux
	[ -d .git ] || git init -q
	if ! git cat-file -e "$KERNEL_COMMIT^{commit}" 2>/dev/null; then
		echo "fetching $KERNEL_COMMIT ..."
		git fetch -q --depth=1 "$KERNEL_REPO" "$KERNEL_COMMIT"
	fi
	if [ -n "$(git status --porcelain 2>/dev/null)" ]; then
		echo "the tree has uncommitted changes; commit or discard them first" >&2; exit 1
	fi
	git checkout -q -B fp6-dev "$KERNEL_COMMIT"
	git am -q /work/fp6-img/$KAPORT/000*.patch
	git log --oneline "$KERNEL_COMMIT"..HEAD'
	;;
kbuild)
	run '
	cd /work/milos-linux
	M="make ARCH=arm64 LLVM=1 O=/work/kbuild LOCALVERSION= -j$(nproc)"
	cp /work/fp6-img/$KAPORT/config-postmarketos-qcom-milos.aarch64 /work/kbuild/.config.aport
	if ! cmp -s /work/kbuild/.config.aport /work/kbuild/.config.from-aport 2>/dev/null; then
		cp /work/kbuild/.config.aport /work/kbuild/.config
		$M olddefconfig
		cp /work/kbuild/.config.aport /work/kbuild/.config.from-aport
	fi
	$M KCFLAGS="-march=armv8.6-a+fp16fml+aes+sha3+sm4 -mtune=cortex-a720" '"${*:-Image.gz dtbs modules}"'
	o=/work/fp6-img/out; mkdir -p $o
	cd /work/kbuild
	cp arch/arm64/boot/Image.gz $o/ 2>/dev/null || true
	cp arch/arm64/boot/dts/$DTB $o/ 2>/dev/null || true
	find drivers/media -name "qcom-camss.ko" -o -name "s5kkd1.ko" | xargs -r cp -t $o/
	cat include/config/kernel.release > $o/kernel.release
	ls -la $o'
	;;
patches)
	run '
	cd /work/milos-linux
	git config --global --add safe.directory /work/milos-linux
	t=/work/fp6-img/$KAPORT
	rm -f $t/000*.patch
	git -c core.abbrev=12 format-patch -q --signature=2.56.0 -o $t "$KERNEL_COMMIT"..HEAD
	ls $t/*.patch
	echo "update source= in $t/APKBUILD if the patch names changed"'
	;;
bootimg)
	[ $# -ge 1 ] || { echo "usage: $0 bootimg <released boot.img> [out.img]" >&2; exit 1; }
	src=$1; out=${2:-out/test-boot.img}
	case "$src" in /*|../*) echo "boot.img must be inside this repository (e.g. out/)" >&2; exit 1 ;; esac
	run "sh /work/fp6-img/tools/mk-test-bootimg.sh '/work/fp6-img/$src' /work/fp6-img/out/$(basename $DTB) '/work/fp6-img/$out'"
	;;
shell)
	TTY=-it run 'bash'
	;;
*)
	echo "unknown command: $cmd" >&2; exit 1
	;;
esac
