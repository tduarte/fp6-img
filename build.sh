#!/bin/sh -eu
# fp6-img pipeline: build a flashable Nura image for the Fairphone 6
# with the Catcrafts kernel (milos-linux combined-stable), imsd (VoLTE) and
# fingerprintd (fingerprint unlock)
# installed from the Catcrafts apk registry.
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
# imsd and fingerprintd are not built here: each repo's package CI publishes
# its apk to the registry, and the image installs the NEWEST published
# version (section 3b), so a fresh install carries the same binary every
# installed phone gets from 'apk upgrade', and a release of either needs no
# commit here. Integrity comes from the same place as on the phones: the
# registry index is verified against the key catcrafts-fp6-repo ships
# (aports/device/, the phones' /etc/apk/keys) and each apk against that
# index, by registry-fetch.py. The resolved versions and sha256s are in the
# build summary. Until 2026-09-11 both were pinned here by version and
# sha256; that gated fresh installs only, never upgrades, and cost a commit
# and an image run per release.
REGISTRY=https://forgejo.catcrafts.net/api/packages/Catcrafts/alpine/edge/fp6
# FP6IMG_UI: which Nura UI the image boots into. plasma-mobile (the
# default) gets imsd-dialerd from the imsd package itself; phosh gets the
# opt-in imsd-ofono subpackage (imsd-ofonod + the GNOME Calls plugin
# override) and fp6-login-screen-schema (GNOME Settings' fingerprint row) on
# top. Everything else in the package set is UI-agnostic. The
# archive is named after it: fp6-img-plasma.tar.xz for plasma-mobile,
# fp6-img-phosh.tar.xz for phosh, so one release can carry both.
FP6IMG_UI=${FP6IMG_UI:-plasma-mobile}
case "$FP6IMG_UI" in
plasma-mobile) UI_PACKAGES=; IMG_NAME=fp6-img-plasma ;;
phosh)         UI_PACKAGES=,imsd-ofono,fp6-login-screen-schema; IMG_NAME=fp6-img-phosh ;;
*) echo "FP6IMG_UI=$FP6IMG_UI: expected plasma-mobile or phosh" >&2; exit 1 ;;
esac
PMAPORTS_REPO=https://gitlab.postmarketos.org/postmarketOS/pmaports.git

cd "$(dirname "$0")"
# Fail in seconds, not at minute 57: a stale sha512sum in one of our own
# aports (run 52, fp6-vendor-blobs 1-r2) only surfaces when abuild reaches that
# aport, an hour into the run. This checks every aport's local source files
# against the committed sums before pmbootstrap does anything.
./check-aports.sh

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
		tar xz curl
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
	# would poison the next podman invocation's cwd). FP6IMG_KEEP_DIST=1 keeps
	# what is there: the second UI build of one run adds its archive next to
	# the first one's.
	install -d -o build dist
	[ -n "${FP6IMG_KEEP_DIST:-}" ] || find dist -mindepth 1 -delete
	# su scrubs the environment — carry the knobs that matter across it
	exec su build -c "FP6IMG_NO_CROSSDIRECT='${FP6IMG_NO_CROSSDIRECT:-}' FP6IMG_UI='${FP6IMG_UI:-}' sh -eu '$PWD/build.sh'"
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
       "$WORK/pmaports/temp/modemmanager"
mkdir -p "$WORK/pmaports/temp"
cp -r aports/device/linux-postmarketos-qcom-milos "$WORK/pmaports/device/testing/"
cp -r aports/device/soc-fairphone-fp6-audio "$WORK/pmaports/device/"
cp -r aports/device/fp6-vendor-blobs "$WORK/pmaports/device/"
cp -r aports/device/callaudioshim "$WORK/pmaports/device/"
cp -r aports/device/fp6-login-screen-schema "$WORK/pmaports/device/"
cp -r aports/device/fp6-device-tweaks "$WORK/pmaports/device/"
cp -r aports/device/fp6-charging-mode "$WORK/pmaports/device/"
cp -r aports/device/catcrafts-fp6-repo "$WORK/pmaports/device/"
cp -r aports/main/postmarketos-config-nftables "$WORK/pmaports/main/"
# imsd has no aport here at all: section 3b installs the published apk.
# Alpine fork carrying the GNSS patches (MM !1463, draft), built from aports
# because r101 > repo. libqmi needs no fork any more: Alpine's snapshot
# (1.38.0_git20261005) is past the !470 merge.
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

# Same dance for the gitlab.freedesktop.org packages (modemmanager,
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
ui = $FP6IMG_UI
systemd = always
extra_packages = soc-fairphone-fp6-audio,callaudioshim,imsd,fingerprintd,fingerprintd-systemd,fingerprintd-agent,fp6-device-tweaks,fp6-charging-mode,catcrafts-fp6-repo,postmarketos-base-ui-audio-backend-pipewire,pipewire-pulse,pipewire-echo-cancel$UI_PACKAGES
EOF

# The local package repository under $WORKDIR is consulted before every
# other repository. Whether it survives from one CI run to the next is not
# established (run 60 rebuilt the packages run 58 had built, which says it
# did not), but nothing guarantees it either way, and a package nobody builds
# any more would win over Alpine's in the builds and in the images: the
# libqmi fork, retired 2026-10-12, as 1.39.1_git20260808. Delete its apks
# from every channel and rebuild the index from the files present (an index
# naming missing apks fails the next apk run), then make sure none is left. pmbootstrap's own 'zap --pkgs-local-mismatch' is no use here:
# with systemd selected it reads packages/systemd-edge, while the builds
# land in packages/edge. The dir belongs to the chroot uid (see 3b).
if [ -d "$WORKDIR/packages" ]; then
	sudo find "$WORKDIR/packages" -name '*.apk' \( -name 'libqmi-*' -o -name 'qmi-utils-*' \) -delete
	retry "re-index local packages" pmbootstrap index
	left=$(sudo find "$WORKDIR/packages" -name '*.apk' \( -name 'libqmi-*' -o -name 'qmi-utils-*' \))
	[ -z "$left" ] || { echo "retired libqmi fork still in the local repository:" >&2; echo "$left" >&2; exit 1; }
fi

# All three source tarballs are generated locally above, so every checksum
# step is offline. libcamera needs a checksum step now too: its committed
# sums were for the fd.o-served tarball, and git-archive output is not
# byte-identical to it (verified: sha512 differs).
pmbootstrap checksum linux-postmarketos-qcom-milos
pmbootstrap checksum modemmanager
pmbootstrap checksum libcamera

# FP6IMG_NO_CROSSDIRECT=1: for local (podman) environments where
# crossdirect's /native bridge breaks ("cc: cannot execute cc1:
# posix_spawnp: No such file or directory" during meson setup); the
# affected packages then build qemu-only — slower, identical output. The
# kernel is unaffected either way (cross-native, no crossdirect).
NOCROSS=${FP6IMG_NO_CROSSDIRECT:+--no-cross}

# Build the patched packages explicitly ('pmbootstrap build' is a no-op when
# the package is already current).
retry "build modemmanager" pmbootstrap $NOCROSS build --arch aarch64 modemmanager
# libcamera is no makedepend of anything here - build it explicitly so the
# patched -r2 exists for the publish step even if the install set resolves
# it before the overlay is considered.
retry "build libcamera" pmbootstrap $NOCROSS build --arch aarch64 libcamera
# --- 3b. imsd + fingerprintd: the published apks, not local builds -----------
# Each repo's package CI is the only producer of its apk; the image installs
# the newest registry package, the one users get via 'apk upgrade'.
# pmbootstrap has no knob for a third-party repository, and after the main
# 'apk add' it re-adds every package found in its local packages dir BY FILE
# PATH — which makes apk verify the package's own signature, and registry
# packages are signed with per-run keys nobody keeps (phones trust the
# registry-signed index instead). So: fetch the newest of each, verified the
# way a phone verifies them (registry-fetch.py: index signature against the
# shipped key, control checksum and data hash against the index), re-sign
# the envelope with this run's abuild key (control and data streams stay
# byte-identical, so the identity checksum equals the registry's), drop into
# the local packages dir, re-index. The abuild key exists because the builds
# above initialized the buildroot. Each group's first name decides the
# version; its subpackages must exist at that same version.
REG_DL="$WORK/registry-apks"
rm -rf "$REG_DL"
mkdir -p "$REG_DL"
REGISTRY_KEY=$(echo aports/device/catcrafts-fp6-repo/*.rsa.pub)
if [ ! -f "$REGISTRY_KEY" ]; then
	echo "expected exactly one registry key in aports/device/catcrafts-fp6-repo" >&2
	exit 1
fi
retry "fetch registry packages" python3 ./registry-fetch.py "$REGISTRY" "$REGISTRY_KEY" "$REG_DL" \
	imsd,imsd-systemd,imsd-ofono fingerprintd,fingerprintd-systemd,fingerprintd-agent
ABUILD_KEY=$(echo "$WORKDIR"/config_abuild/*.rsa)
if [ ! -f "$ABUILD_KEY" ]; then
	echo "expected exactly one abuild key in $WORKDIR/config_abuild" >&2
	exit 1
fi
# abuild-keygen ran inside the chroot as pmbootstrap's user (uid 12345), so
# the key is 0600 to that uid and unreadable here (run 49 died on exactly
# this); sign from a private copy taken via sudo, then drop it.
KEYCOPY="$REG_DL/abuild-key.rsa"
sudo install -m 0600 -o "$(id -un)" "$ABUILD_KEY" "$KEYCOPY"
for _f in "$REG_DL"/*.apk; do
	python3 ./apk-resign.py "$_f" "$KEYCOPY" "$(basename "$ABUILD_KEY").pub"
done
rm -f "$KEYCOPY"
# The packages dir belongs to pmbootstrap's chroot user as well (abuild wrote
# it from inside the chroot), so the build user cannot write there either
# (run 50): install the files with the directory's own owner, as abuild would
# have left them. The dir exists because the builds above populated it.
PKGDIR="$WORKDIR/packages/edge/aarch64"
if [ ! -d "$PKGDIR" ]; then
	echo "$PKGDIR missing - the package builds above should have created it" >&2
	exit 1
fi
for _f in "$REG_DL"/*.apk; do
	sudo install -m 0644 -o "$(stat -c %u "$PKGDIR")" -g "$(stat -c %g "$PKGDIR")" \
		"$_f" "$PKGDIR/$(basename "$_f")"
done
rm -f "$REG_DL"/*.apk
pmbootstrap index

# --- 4. build the image -------------------------------------------------------
# Same default credentials as the official Nura images.
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
mkdir -p "$STAGE/$IMG_NAME"
ln -s "$EXPORT/boot.img" "$STAGE/$IMG_NAME/boot.img"
ln -s "$EXPORT/fairphone-fp6.img" "$STAGE/$IMG_NAME/fairphone-fp6.img"
cp README.md install.sh "$STAGE/$IMG_NAME/"
{
	echo "kernel:        $KERNEL_REPO $KERNEL_BRANCH @ $COMMIT"
	echo "ui:            $FP6IMG_UI"
	echo "built:         $(date -u +%Y-%m-%dT%H:%M:%SZ)"
	echo "default login: user / 147147 (same as official Nura images)"
	while read -r _n _v _s; do
		printf '%-14s %s %s-%s (newest registry package, sha256 %s)\n' "$_n:" "$REGISTRY" "$_n" "$_v" "$_s"
	done < "$REG_DL/manifest"
} > "$STAGE/$IMG_NAME/build-info.txt"
# sums of the extracted contents
(cd "$STAGE/$IMG_NAME" && sha256sum -- * > sha256sums.txt)
tar -C "$STAGE" -chf - "$IMG_NAME" | xz -T0 -6 > "dist/$IMG_NAME.tar.xz"
rm -rf "$STAGE"

ls -la dist/
