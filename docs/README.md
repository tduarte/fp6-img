# Working notes for this fork

This repository is a copy of [Catcrafts/fp6-img](https://forgejo.catcrafts.net/Catcrafts/fp6-img)
(branch `upstream` tracks its `main`) plus local changes on `main`:

- `aports/temp/libcamera`: the libcamera fork moved to 0.8.0 (sensor helpers,
  contrast autofocus, AWB locus clamp), release r102.
- `aports/device/linux-postmarketos-qcom-milos/000*.patch`: a kernel patch queue
  applied on top of the pinned `combined-stable` commit (`KERNEL_COMMIT` in
  `build.sh`): two CAMSS fixes, the S5KKD1 front-camera driver and its DT node.
- `docs/`: the camera diagnosis and a hardware status table.
- `tools/`: helpers used during bring-up.

State as of 2026-11-14: the libcamera packages were built and tested on a phone.
The kernel patches were tested by RAM boot with hand-loaded modules only. The
changes to `build.sh` and the kernel aport have NOT been run through the image
build, and there is no GitHub Actions workflow yet (`.forgejo/workflows/build.yml`
is the upstream one and needs a privileged runner).

Not in this repository, on purpose: the vendor files read from the phone's stock
partitions, partition dumps and captured photos.

## tools/

| File | Runs on | Purpose |
|---|---|---|
| `decode_sensormodule.py` | host | Decode register tables from a CamX sensormodule `.bin` |
| `gen_s5kkd1.py` | host | Generate `s5kkd1.c` from `s5kjn1.c` and the decoded tables |
| `kbuild.sh` | Alpine container with clang | Build the kernel tree with the phone's config |
| `mk-test-bootimg.sh` | host | Stock kernel + ramdisk with a new DTB, for `fastboot boot` |
| `cycle.sh` | host | Reboot to bootloader, RAM-boot, swap in test modules |
| `front-capture.sh` | phone | Route the front sensor through CAMSS and capture raw frames |
| `raw2jpg.py` | host | Quick-look conversion of packed RAW10 Bayer to JPEG |
| `libcamera-build-apk.sh` | aarch64 Alpine container | Build the libcamera aport with abuild |

## Kernel development on macOS (Apple Silicon)

The kernel is built in a native arm64 Alpine container (`dev/Dockerfile`,
driven by `dev.sh`); the phone is driven from macOS, since Docker Desktop
cannot pass USB through. Host needs: Docker Desktop, `brew install
android-platform-tools` (fastboot), ssh. The kernel tree and build output live
in the Docker volumes `fp6-milos-linux` and `fp6-kbuild` (case-sensitive);
results land in `out/` (git-ignored).

```sh
./dev.sh image     # once: build the fp6-dev container image
./dev.sh src       # pinned KERNEL_COMMIT + the aport's 000*.patch as commits
./dev.sh kbuild    # Image.gz, dtbs, modules -> out/ (camss, s5kkd1, dtb)
./dev.sh shell     # hack in /work/milos-linux, commit, then:
./dev.sh patches   # export the commits back to the aport's 000*.patch
./dev.sh bootimg out/boot.img   # released boot.img + out/ dtb -> out/test-boot.img
```

The same `dev.sh` works on a Linux host (Docker or Podman): on x86_64 the
container cross-compiles with clang, which needs no extra toolchain. The
volumes are per machine, so kernel work moves between machines only as
commits in this repository: `./dev.sh patches`, commit, pull on the other
machine, `./dev.sh src`. On Linux the phone can also be driven from the host
the same way, with `ip`/`nmcli` for the USB network (see `install.sh`).

The phone's USB network (172.16.42.1) comes up on macOS as a CDC-NCM
interface and normally gets 172.16.42.2 by DHCP. `install.sh` and
`tools/cycle.sh` fall back to `gtimeout` or perl where macOS has no
`timeout`. Only ever `fastboot boot` test images; `fastboot flash boot` wipes
the modem NV on this phone.
