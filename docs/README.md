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
