#!/bin/sh -eu
# fp6-img pipeline: build a flashable postmarketOS image for the Fairphone 6
# with the Catcrafts kernel (milos-linux combined-stable) and, once its tag
# is published, imsd (VoLTE).
#
# Runs in CI inside an Alpine container on the privileged "pmos" runner
# (pmbootstrap needs loop devices; the aarch64 chroots need the qemu-user
# binfmt registered on the host). Also runnable in any Alpine environment
# with the same privileges.

KERNEL_REPO=https://forgejo.catcrafts.net/Catcrafts/milos-linux.git
KERNEL_BRANCH=combined-stable
PMAPORTS_REPO=https://gitlab.postmarketos.org/postmarketOS/pmaports.git

cd "$(dirname "$0")"

# pmbootstrap refuses to run as root: install deps, then re-exec as a build
# user with passwordless sudo (pmbootstrap escalates itself where needed).
if [ "$(id -u)" = 0 ]; then
	apk add -q pmbootstrap git sudo
	id build >/dev/null 2>&1 || adduser -D build
	echo 'build ALL=(ALL) NOPASSWD: ALL' > /etc/sudoers.d/build
	chown -R build "$PWD"
	exec su build -c "sh '$PWD/build.sh'"
fi

WORK=${FP6IMG_WORK:-$HOME/fp6img-work}
mkdir -p "$WORK"

# --- 1. pmaports with our aports copied over ---------------------------------
# pmbootstrap hard-errors when a pkgname exists in more than one aports dir,
# so "overlay" means: clone upstream, delete the upstream aport, drop ours in.
rm -rf "$WORK/pmaports"
git clone -q --depth=1 "$PMAPORTS_REPO" "$WORK/pmaports"
rm -rf "$WORK/pmaports/device/testing/linux-postmarketos-qcom-milos" \
       "$WORK/pmaports/main/postmarketos-config-nftables"
cp -r aports/device/linux-postmarketos-qcom-milos "$WORK/pmaports/device/testing/"
cp -r aports/main/postmarketos-config-nftables "$WORK/pmaports/main/"
cp -r aports/modem/imsd "$WORK/pmaports/modem/"

# --- 2. pin the kernel source -------------------------------------------------
# Source archives are disabled on the Forgejo instance, so generate the
# tarball ourselves; abuild treats it as a local source file.
rm -rf "$WORK/milos-src"
git clone -q --depth=1 -b "$KERNEL_BRANCH" "$KERNEL_REPO" "$WORK/milos-src"
COMMIT=$(git -C "$WORK/milos-src" rev-parse HEAD)
KAPORT="$WORK/pmaports/device/testing/linux-postmarketos-qcom-milos"
git -C "$WORK/milos-src" archive --prefix=milos-linux/ \
	-o "$KAPORT/milos-linux-$COMMIT.tar.gz" HEAD
sed -i "s/^_commit=.*/_commit=\"$COMMIT\"/" "$KAPORT/APKBUILD"

# --- 3. configure pmbootstrap -------------------------------------------------
pmbootstrap config aports "$WORK/pmaports"
pmbootstrap config device fairphone-fp6
pmbootstrap config ui plasma-mobile
pmbootstrap config systemd always
# Stage 1 builds WITHOUT imsd: its aport sources the v0.3.0 tag, which is not
# published yet. When it is: uncomment here and in the checksum step below.
#pmbootstrap config extra_packages imsd

pmbootstrap checksum linux-postmarketos-qcom-milos
#pmbootstrap checksum imsd

# --- 4. build the image -------------------------------------------------------
# Same default credentials as the official postmarketOS images.
pmbootstrap -y zap >/dev/null 2>&1 || true
pmbootstrap install --password 147147

# --- 5. collect artifacts -----------------------------------------------------
EXPORT=/tmp/postmarketOS-export
rm -rf "$EXPORT" dist
mkdir -p dist
pmbootstrap export "$EXPORT"
cp -L "$EXPORT/boot.img" dist/boot.img
cp -L "$EXPORT/fairphone-fp6.img" dist/fairphone-fp6.img

{
	echo "kernel:        $KERNEL_REPO $KERNEL_BRANCH @ $COMMIT"
	echo "built:         $(date -u +%Y-%m-%dT%H:%M:%SZ)"
	echo "default login: user / 147147 (same as official postmarketOS images)"
	echo "imsd:          not included yet (waiting on the v0.3.0 tag)"
} > dist/build-info.txt
cp README.md dist/README.md

(cd dist && sha256sum -- * > sha256sums.txt)
ls -la dist/
