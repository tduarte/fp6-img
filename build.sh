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

# HOST REQUIREMENT: the loop driver must be loaded on the host kernel
# (modprobe loop + modules-load.d entry). Containers cannot load host
# modules, and on some kernels opening /dev/loop-control from a container
# does not autoload the driver either.

KERNEL_REPO=https://forgejo.catcrafts.net/Catcrafts/milos-linux.git
KERNEL_BRANCH=combined-stable
IMSD_REPO=https://forgejo.catcrafts.net/Catcrafts/imsd.git
# imsd 0.3.0: what the dev phone runs (0.2.7) + emergency-calling stage 1 +
# the make build path the aport needs. Bump deliberately, not via tip-chasing.
IMSD_COMMIT=1037958
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
	# The container must run with the host's /dev bind-mounted
	# (--volume /dev:/dev): partition nodes (loopNpM) appear via devtmpfs
	# only there — a privileged container's own /dev is a stale snapshot
	# from container start and never gains them.
	if ! grep -q ' /dev devtmpfs ' /proc/mounts; then
		echo "WARNING: /dev is not the host devtmpfs (run the container" \
		     "with --volume /dev:/dev) - partition nodes will not appear" >&2
	fi
	id build >/dev/null 2>&1 || adduser -D build
	echo 'build ALL=(ALL) NOPASSWD: ALL' > /etc/sudoers.d/build
	# empty dist in place (never delete the dir itself: a shell cd'd into it
	# would poison the next podman invocation's cwd)
	install -d -o build dist
	find dist -mindepth 1 -delete
	exec su build -c "sh -eu '$PWD/build.sh'"
fi

# git hosts occasionally hiccup (our forgejo lives on a small VM that also
# serves crawlers); a clone failure should cost a retry, not the whole run
clone_retry() { # clone_retry <dest> <git clone args...>
	_dest=$1; shift
	for _i in 1 2 3; do
		rm -rf "$_dest"
		git clone "$@" "$_dest" && return 0
		echo "git clone $_dest failed (attempt $_i/3), retrying in 10s..." >&2
		sleep 10
	done
	echo "git clone $_dest failed after 3 attempts" >&2
	return 1
}

WORK=${FP6IMG_WORK:-$HOME/fp6img-work}
mkdir -p "$WORK"

# pmbootstrap swallows its subcommands' stderr into its own log; surface it
# whenever this script dies so failures are diagnosable from the CI/console
# output alone.
trap 'rc=$?; if [ $rc -ne 0 ]; then
	echo "=== build.sh failed (exit $rc); pmbootstrap log tail ==="
	tail -60 "$HOME/.local/var/pmbootstrap/log.txt" 2>/dev/null || true
fi' EXIT

# --- 1. pmaports with our aports copied over ---------------------------------
# pmbootstrap hard-errors when a pkgname exists in more than one aports dir,
# so "overlay" means: clone upstream, delete the upstream aport, drop ours in.

clone_retry "$WORK/pmaports" -q --depth=1 "$PMAPORTS_REPO"
rm -rf "$WORK/pmaports/device/testing/linux-postmarketos-qcom-milos" \
       "$WORK/pmaports/main/postmarketos-config-nftables" \
       "$WORK/pmaports/temp/libqmi" \
       "$WORK/pmaports/temp/modemmanager"
mkdir -p "$WORK/pmaports/temp"
cp -r aports/device/linux-postmarketos-qcom-milos "$WORK/pmaports/device/testing/"
cp -r aports/device/soc-fairphone-fp6-audio "$WORK/pmaports/device/"
cp -r aports/device/callaudioshim "$WORK/pmaports/device/"
cp -r aports/device/fp6-device-tweaks "$WORK/pmaports/device/"
cp -r aports/main/postmarketos-config-nftables "$WORK/pmaports/main/"
cp -r aports/modem/imsd "$WORK/pmaports/modem/"
# Alpine forks carrying the GNSS patches (libqmi !470 unreleased; MM !1463
# draft) - deps of modemmanager/imsd, built from aports because r100 > repo.
cp -r aports/temp/libqmi "$WORK/pmaports/temp/"
cp -r aports/temp/modemmanager "$WORK/pmaports/temp/"

# --- 2. pin the kernel source -------------------------------------------------
# Source archives are disabled on the Forgejo instance, so generate the
# tarball ourselves; abuild treats it as a local source file.

clone_retry "$WORK/milos-src" -q --depth=1 -b "$KERNEL_BRANCH" "$KERNEL_REPO"
COMMIT=$(git -C "$WORK/milos-src" rev-parse HEAD)
KAPORT="$WORK/pmaports/device/testing/linux-postmarketos-qcom-milos"
git -C "$WORK/milos-src" archive --prefix=milos-linux/ \
	-o "$KAPORT/milos-linux-$COMMIT.tar.gz" HEAD
sed -i "s/^_commit=.*/_commit=\"$COMMIT\"/" "$KAPORT/APKBUILD"
# Stamp the kernel pkgver with the source commit date (7.1.2 ->
# 7.1.2_git20260808): a rebuilt combined-stable must produce a HIGHER
# package version, or phones subscribed to the package registry would
# never see kernel updates.
KDATE=$(git -C "$WORK/milos-src" log -1 --format=%cd --date=format:%Y%m%d)
sed -i "s/^pkgver=\([0-9.]*\)\$/pkgver=\1_git$KDATE/" "$KAPORT/APKBUILD"

# Same dance for imsd, pinned to a reviewed commit rather than branch tip.

clone_retry "$WORK/imsd-src" -q "$IMSD_REPO"
git -C "$WORK/imsd-src" checkout -q "$IMSD_COMMIT"
IAPORT="$WORK/pmaports/modem/imsd"
git -C "$WORK/imsd-src" archive --prefix=imsd/ \
	-o "$IAPORT/imsd-$IMSD_COMMIT.tar.gz" HEAD
sed -i "s/^_commit=.*/_commit=\"$IMSD_COMMIT\"/" "$IAPORT/APKBUILD"

# --- 3. configure pmbootstrap -------------------------------------------------
# 'pmbootstrap config' refuses to run before a config exists ("run init
# first"), so write the config file directly (INI, [pmbootstrap] section,
# keys = pmb.core.Config attributes).
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
extra_packages = soc-fairphone-fp6-audio,callaudioshim,imsd,fp6-device-tweaks,postmarketos-base-ui-audio-backend-pipewire,pipewire-pulse,pipewire-echo-cancel
EOF

pmbootstrap checksum linux-postmarketos-qcom-milos
pmbootstrap checksum imsd
pmbootstrap checksum libqmi
pmbootstrap checksum modemmanager

# pmbootstrap's install-time build plan is not dependency-ordered (it tried
# building modemmanager before the libqmi its makedepends require); build
# the GNSS stack bottom-up explicitly. 'pmbootstrap build' is a no-op when
# the package is already current.
pmbootstrap build --arch aarch64 libqmi
pmbootstrap build --arch aarch64 modemmanager

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
	echo "imsd:          $IMSD_REPO @ $IMSD_COMMIT (0.3.0)"
} > dist/build-info.txt
cp README.md dist/README.md
cp install.sh dist/install.sh

(cd dist && sha256sum -- * > sha256sums.txt)
ls -la dist/
