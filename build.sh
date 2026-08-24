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
	apk add -q git sudo openssl python3 py3-pip multipath-tools util-linux \
		tar xz
	# the pmOS gitlab hiccups under crawler load and truncates clones
	# ("early EOF"); that should cost a retry, not the run — same reasoning
	# as clone_retry below, which isn't defined yet in this root branch
	for _i in 1 2 3; do
		pip install -q --break-system-packages \
			git+https://gitlab.postmarketos.org/postmarketOS/pmbootstrap.git@3.11.1 \
			&& break
		if [ "$_i" = 3 ]; then
			echo "pmbootstrap pip install failed after 3 attempts" >&2
			exit 1
		fi
		echo "pmbootstrap pip install failed (attempt $_i/3), retrying in 15s..." >&2
		sleep 15
	done
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
	# su scrubs the environment — carry the knobs that matter across it
	exec su build -c "FP6IMG_NO_CROSSDIRECT='${FP6IMG_NO_CROSSDIRECT:-}' sh -eu '$PWD/build.sh'"
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

# Build steps still install their makedepends over the network; same
# reasoning as clone_retry: a transient mirror hiccup should cost a retry,
# not the run. (The gitlab.freedesktop.org archive fetches that killed runs
# #25/#27/#30/#31 are gone — section 2 generates those tarballs locally.)
retry() { # retry <description> <cmd...>
	_desc=$1; shift
	for _i in 1 2 3; do
		"$@" && return 0
		echo "$_desc failed (attempt $_i/3), retrying in 30s..." >&2
		sleep 30
	done
	echo "$_desc failed after 3 attempts" >&2
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
       "$WORK/pmaports/temp/libcamera" \
       "$WORK/pmaports/temp/libqmi" \
       "$WORK/pmaports/temp/modemmanager"
mkdir -p "$WORK/pmaports/temp"
cp -r aports/device/linux-postmarketos-qcom-milos "$WORK/pmaports/device/testing/"
cp -r aports/device/soc-fairphone-fp6-audio "$WORK/pmaports/device/"
cp -r aports/device/callaudioshim "$WORK/pmaports/device/"
cp -r aports/device/fp6-device-tweaks "$WORK/pmaports/device/"
cp -r aports/device/fp6-charging-mode "$WORK/pmaports/device/"
cp -r aports/device/catcrafts-fp6-repo "$WORK/pmaports/device/"
cp -r aports/main/postmarketos-config-nftables "$WORK/pmaports/main/"
cp -r aports/modem/imsd "$WORK/pmaports/modem/"
# Alpine forks carrying the GNSS patches (libqmi !470 unreleased; MM !1463
# draft) - deps of modemmanager/imsd, built from aports because r100 > repo.
cp -r aports/temp/libqmi "$WORK/pmaports/temp/"
cp -r aports/temp/modemmanager "$WORK/pmaports/temp/"
# pmOS libcamera fork + the FP6 OV13B10 sensor-helper/properties patches
# (r2 > pmOS r1)
cp -r aports/temp/libcamera "$WORK/pmaports/temp/"

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

# Same again for the gitlab.freedesktop.org packages (libqmi, modemmanager,
# libcamera): their pinned tarballs came from fd.o's on-demand archive
# endpoint, which 503/504s for hours at a stretch — runs #25, #27, #30 and
# #31 all died there, outlasting any in-run retry. git clone is served from
# a different code path and holds up; generate the tarballs ourselves. The
# pins stay single-sourced in the APKBUILDs, read back out here.

apkbuild_var() { # apkbuild_var <aport dir> <variable>
	sed -n "s/^$2=//p" "$1/APKBUILD" | tr -d '"'
}

fdo_tarball() { # fdo_tarball <repo url> <aport dir> <tarball dirname> <ref>
	clone_retry "$WORK/fdo-src" -q --bare "$1"
	git -C "$WORK/fdo-src" archive --prefix="$3/" -o "$2/$3.tar.gz" "$4"
	rm -rf "$WORK/fdo-src"
}

FDO=https://gitlab.freedesktop.org
QMI_COMMIT=$(apkbuild_var "$WORK/pmaports/temp/libqmi" _commit)
fdo_tarball "$FDO/mobile-broadband/libqmi.git" \
	"$WORK/pmaports/temp/libqmi" "libqmi-$QMI_COMMIT" "$QMI_COMMIT"
MM_COMMIT=$(apkbuild_var "$WORK/pmaports/temp/modemmanager" _commit)
fdo_tarball "$FDO/mobile-broadband/ModemManager.git" \
	"$WORK/pmaports/temp/modemmanager" "ModemManager-$MM_COMMIT" "$MM_COMMIT"
CAM_VER=$(apkbuild_var "$WORK/pmaports/temp/libcamera" _pkgver)
fdo_tarball "$FDO/camera/libcamera.git" \
	"$WORK/pmaports/temp/libcamera" "libcamera-v$CAM_VER" "v$CAM_VER"

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
extra_packages = soc-fairphone-fp6-audio,callaudioshim,imsd,fp6-device-tweaks,fp6-charging-mode,catcrafts-fp6-repo,postmarketos-base-ui-audio-backend-pipewire,pipewire-pulse,pipewire-echo-cancel
EOF

# All five source tarballs are generated locally above, so every checksum
# step is offline. libcamera needs a checksum step now too: its committed
# sums were for the fd.o-served tarball, and git-archive output is not
# byte-identical to it (verified: sha512 differs).
pmbootstrap checksum linux-postmarketos-qcom-milos
pmbootstrap checksum imsd
pmbootstrap checksum libqmi
pmbootstrap checksum modemmanager
pmbootstrap checksum libcamera

# FP6IMG_NO_CROSSDIRECT=1: for local (podman) environments where
# crossdirect's /native bridge breaks ("cc: cannot execute cc1:
# posix_spawnp: No such file or directory" during meson setup); the
# affected packages then build qemu-only — slower, identical output. The
# kernel is unaffected either way (cross-native, no crossdirect).
NOCROSS=${FP6IMG_NO_CROSSDIRECT:+--no-cross}

# pmbootstrap's install-time build plan is not dependency-ordered (it tried
# building modemmanager before the libqmi its makedepends require); build
# the GNSS stack bottom-up explicitly. 'pmbootstrap build' is a no-op when
# the package is already current.
retry "build libqmi" pmbootstrap $NOCROSS build --arch aarch64 libqmi
retry "build modemmanager" pmbootstrap $NOCROSS build --arch aarch64 modemmanager
# libcamera is no makedepend of anything here - build it explicitly so the
# patched -r2 exists for the publish step even if the install set resolves
# it before the overlay is considered.
retry "build libcamera" pmbootstrap $NOCROSS build --arch aarch64 libcamera
# imsd is the one crossdirect build left to the install phase, which has no
# per-package flag — pre-build it here in no-crossdirect mode so install
# finds it current.
if [ -n "$NOCROSS" ]; then
	retry "build imsd" pmbootstrap $NOCROSS build --arch aarch64 imsd
fi

# --- 4. build the image -------------------------------------------------------
# Same default credentials as the official postmarketOS images.
pmbootstrap -y zap >/dev/null 2>&1 || true
pmbootstrap install --password 147147

# --- 5. collect artifacts -----------------------------------------------------
EXPORT=/tmp/postmarketOS-export
rm -rf "$EXPORT"
pmbootstrap export "$EXPORT"

# Everything ships as ONE archive, and dist/ holds nothing else: the rootfs is
# 3.0 GiB raw and 812 MiB under xz -6 (gzip -6 stops at 1144 MiB), and a bundle
# makes it impossible to pair a boot.img with a rootfs from a different build.
# README/install.sh are not attached loose as well — they are readable in the
# repository, and a second copy in the release only invites reading a stale one
# (and a loose sha256sums.txt next to the archive's own is pure confusion).
#
# pmbootstrap export writes symlinks into its work dir; tar -h resolves them,
# so the archive is built without a second 3 GiB copy on disk.
STAGE="$WORK/stage"
rm -rf "$STAGE"
mkdir -p "$STAGE/fp6-img"
ln -s "$EXPORT/boot.img" "$STAGE/fp6-img/boot.img"
ln -s "$EXPORT/fairphone-fp6.img" "$STAGE/fp6-img/fairphone-fp6.img"
cp README.md install.sh "$STAGE/fp6-img/"
{
	echo "kernel:        $KERNEL_REPO $KERNEL_BRANCH @ $COMMIT"
	echo "built:         $(date -u +%Y-%m-%dT%H:%M:%SZ)"
	echo "default login: user / 147147 (same as official postmarketOS images)"
	echo "imsd:          $IMSD_REPO @ $IMSD_COMMIT (0.3.0)"
} > "$STAGE/fp6-img/build-info.txt"
# sums of the extracted contents
(cd "$STAGE/fp6-img" && sha256sum -- * > sha256sums.txt)
tar -C "$STAGE" -chf - fp6-img | xz -T0 -6 > dist/fp6-img.tar.xz
rm -rf "$STAGE"

ls -la dist/
