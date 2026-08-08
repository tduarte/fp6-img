#!/bin/sh -eu
# fp6-img pipeline: build a flashable postmarketOS image for the Fairphone 6
# with the Catcrafts kernel (milos-linux combined-stable) and, once its tag
# is published, imsd (VoLTE).
#
# Runs in CI inside an Alpine container on the privileged "pmos" runner
# (pmbootstrap needs loop devices; the aarch64 chroots need the qemu-user
# binfmt registered on the host). Also runnable in any Alpine environment
# with the same privileges.

set -eu

KERNEL_REPO=https://forgejo.catcrafts.net/Catcrafts/milos-linux.git
KERNEL_BRANCH=combined-stable
PMAPORTS_REPO=https://gitlab.postmarketos.org/postmarketOS/pmaports.git

cd "$(dirname "$0")"

# pmbootstrap refuses to run as root: install deps, then re-exec as a build
# user with passwordless sudo (pmbootstrap escalates itself where needed).
# The checkout stays root-owned (later workflow steps need its .git); the
# build user only gets dist/.
if [ "$(id -u)" = 0 ]; then
	# pmbootstrap pinned from git: Alpine's package is older and e.g. still
	# reads channels.cfg from origin/master (upstream pmaports moved to main).
	# multipath-tools: kpartx; util-linux: losetup with --json support
	# (pmbootstrap's host-tool checks + image mounting need both)
	apk add -q git sudo openssl python3 py3-pip multipath-tools util-linux
	pip install -q --break-system-packages \
		git+https://gitlab.postmarketos.org/postmarketOS/pmbootstrap.git@3.11.1
	# The container cannot modprobe (no /lib/modules in here), but it doesn't
	# need to: the host kernel autoloads the loop driver when losetup opens
	# the static /dev/loop-control node. Make pmbootstrap's explicit
	# 'sudo modprobe loop' a no-op (/usr/local/sbin precedes /sbin in sudo's
	# secure_path).
	mkdir -p /usr/local/sbin
	printf '#!/bin/sh\nexit 0\n' > /usr/local/sbin/modprobe
	chmod +x /usr/local/sbin/modprobe
	# A privileged container's /dev is a snapshot from container start —
	# loop/dm nodes the host creates later never appear. Create the static
	# nodes here; opening them autoloads the drivers host-side (reserved
	# major/minors: loop = block 7,N; device-mapper control = char 10,236).
	i=0
	while [ $i -le 15 ]; do
		[ -b /dev/loop$i ] || mknod -m 660 /dev/loop$i b 7 $i
		i=$((i + 1))
	done
	mkdir -p /dev/mapper
	[ -c /dev/mapper/control ] || mknod -m 600 /dev/mapper/control c 10 236
	id build >/dev/null 2>&1 || adduser -D build
	echo 'build ALL=(ALL) NOPASSWD: ALL' > /etc/sudoers.d/build
	rm -rf dist
	install -d -o build dist
	exec su build -c "sh -eu '$PWD/build.sh'"
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
# 'pmbootstrap config' refuses to run before a config exists ("run init
# first"), so write the config file directly (INI, [pmbootstrap] section,
# keys = pmb.core.Config attributes).
# Stage 1 builds WITHOUT imsd: its aport sources the v0.3.0 tag, which is not
# published yet. When it is: add "extra_packages = imsd" and enable the
# checksum line below.
# 'init' would also create the work dir and stamp its migration version;
# do both ourselves (version derived from the installed pmb, not hardcoded).
WORKDIR="$HOME/.local/var/pmbootstrap"
mkdir -p "$WORKDIR/cache_git"
python3 -c "import pmb.config; print(pmb.config.work_version)" > "$WORKDIR/version"

mkdir -p "$HOME/.config"
cat > "$HOME/.config/pmbootstrap_v3.cfg" <<EOF
[pmbootstrap]
aports = $WORK/pmaports
device = fairphone-fp6
ui = plasma-mobile
systemd = always
EOF

pmbootstrap checksum linux-postmarketos-qcom-milos
#pmbootstrap checksum imsd

# --- 4. build the image -------------------------------------------------------
# Same default credentials as the official postmarketOS images.
pmbootstrap -y zap >/dev/null 2>&1 || true
pmbootstrap install --password 147147

# --- 5. collect artifacts -----------------------------------------------------
EXPORT=/tmp/postmarketOS-export
rm -rf "$EXPORT"
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
