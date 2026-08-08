#!/bin/sh -eu
# fp6-img pipeline: build a flashable postmarketOS image for the Fairphone 6
# with the Catcrafts kernel (milos-linux combined-stable) and imsd (VoLTE).
#
# Runs in CI inside an Alpine container on a privileged runner (pmbootstrap
# needs loop devices; the aarch64 chroots need qemu-user binfmt on the host).
# Also runnable locally in any Alpine environment with the same privileges.
#
# Status: SCAFFOLD — steps marked TODO(validate) have not run end-to-end yet.

KERNEL_REPO=https://forgejo.catcrafts.net/Catcrafts/milos-linux.git
KERNEL_BRANCH=combined-stable
KERNEL_APORT=aports/device/linux-postmarketos-qcom-milos

cd "$(dirname "$0")"

apk add -q pmbootstrap git zstd

# --- 1. Pin the kernel source ------------------------------------------------
# Source archives are disabled on the Forgejo instance, so generate the
# tarball ourselves and let abuild treat it as a local source file.
rm -rf /tmp/milos-src "$KERNEL_APORT"/milos-linux-*.tar.gz
git clone --depth=1 -b "$KERNEL_BRANCH" "$KERNEL_REPO" /tmp/milos-src
COMMIT=$(git -C /tmp/milos-src rev-parse HEAD)
git -C /tmp/milos-src archive --prefix=milos-linux/ \
    -o "$PWD/$KERNEL_APORT/milos-linux-$COMMIT.tar.gz" HEAD
sed -i "s/^_commit=.*/_commit=\"$COMMIT\"/" "$KERNEL_APORT/APKBUILD"

# --- 2. Configure pmbootstrap ------------------------------------------------
# TODO(validate): exact non-interactive init + overlay ordering (our aports
# dir must shadow the upstream pmaports aports of the same name).
pmbootstrap config device fairphone-fp6
pmbootstrap config ui plasma-mobile
pmbootstrap config systemd always
pmbootstrap config extra_packages imsd,postmarketos-config-nftables-imsd
# TODO(validate): point pmbootstrap at "$PWD/aports" as an overlay.

pmbootstrap checksum linux-postmarketos-qcom-milos
pmbootstrap checksum imsd

# --- 3. Build the image ------------------------------------------------------
# Same default credentials as the official postmarketOS images.
pmbootstrap -y zap || true
pmbootstrap install --password 147147

# --- 4. Collect artifacts ----------------------------------------------------
# TODO(validate): exact export paths (boot.img + rootfs) for the fastboot
# flash method on fairphone-fp6.
rm -rf /tmp/pmos-export dist
mkdir -p /tmp/pmos-export dist
pmbootstrap export /tmp/pmos-export
cp -L /tmp/pmos-export/boot.img dist/fp6-boot.img
cp -L /tmp/pmos-export/*.img dist/ 2>/dev/null || true

{
    echo "kernel:        $KERNEL_REPO $KERNEL_BRANCH @ $COMMIT"
    echo "built:         $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "default login: user / 147147 (same as official postmarketOS images)"
} > dist/build-info.txt
cp README.md dist/README.md

(cd dist && sha256sum -- * > sha256sums.txt)
ls -la dist/
