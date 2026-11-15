# Fairphone 6 cameras on Catcrafts Nura (Phosh) — diagnosis

Date: 2026-11-14. Image: fp6-img phosh, kernel 7.3.0 `combined-stable` @ `27825d9f`,
libcamera 0.8.0, PipeWire 1.6.11, camera app GNOME Snapshot 51.

Checked on the phone as the unprivileged `user` (no root yet): kernel journal,
`/proc/device-tree`, sysfs I2C bindings, media entity names, PipeWire/libcamera logs.
Not yet done (needs root): `dmesg` debug, `media-ctl -p`, `cam -l`, raw frame captures.

## Hardware and what the kernel sees

| Camera | Sensor | Bus | Kernel state |
|---|---|---|---|
| Main | Sony IMX896 (LYT-700C), C-PHY | cci0 bus 0 @ 0x1a | driver bound, in media graph |
| Main AF/OIS | Dongwoon DW9784 | cci0 bus 0 @ 0x72 | bound, chip id 0x9784, fw 0x0302 |
| Ultra-wide | OmniVision OV13B10 | cci0 bus 1 @ 0x36 | bound (dummy dovdd/dvdd regulators) |
| Ultra-wide AF | DW9714 | cci0 bus 1 @ 0x0c | bound |
| Front | Samsung S5KKD1SP | cci1 bus 1 @ 0x3d | **no DT node, no driver** |
| Front AF | Awinic AW86016 | cci1 bus 1 @ 0x0c | no DT node, no mainline driver |
| ToF | ST VL53L3 | i2c4 @ 0x29 | DT node present, no driver bound |

No probe errors for camss, cci, or the two rear sensors.

## Front camera: does not exist as far as Linux is concerned

Kind: **missing DT node + driver disabled + missing firmware + userspace gap.**

1. `cci@ac16000/i2c-bus@1` contains only `eeprom@51`. The `camera@3d` node lives on
   the maintainer's `camera-front` branch (2 commits on top of combined-stable,
   `6364e2999c` and `d0935726b7`), which is not merged.
2. The image config has `# CONFIG_VIDEO_CCS is not set`; that branch drives the
   sensor with the generic MIPI CCS driver.
3. The sensor is only partly CCS-compliant and needs a static-data override file
   `ccs/ccs-module-0300-4841-a002.fw`. It is not in the kernel repo or the image
   (the commit points at a private `journal/camera/captures/2026-08-23-*`).
4. Maintainer's own status: probes, full graph registers, **streaming untested**,
   and libcamera does not expose it (`camera_sensor_legacy: no image format`,
   because CCS presents the sensor as several sub-devices).
5. No autofocus driver for the AW86016 exists.

## Main camera: kernel fine, userspace untuned

Kind: **libcamera software-ISP limits, not a kernel fault.**

libcamera log at camera start:

- `No static properties available for 'imx896'` → guessed sensor delays.
- `Failed to create camera sensor helper for imx896` → the soft ISP cannot map gain
  codes, so auto-exposure/gain behaves badly.
- `Configuration file 'imx896.yaml' not found ... falling back to uncalibrated.yaml`
  → no measured black level, no colour-correction matrix (flat, tinted colours).
- libcamera's `simple` pipeline has no autofocus algorithm; nothing drives the
  DW9784, so the lens sits wherever it powers up (likely blurry).
- Stream is 1920x1080 debayered from the 4096x3072 binned mode; whether the GPU or
  CPU debayer is used is not yet confirmed (libcamera links EGL/GLES).
- Both rear cameras are advertised as "Built-in Back Camera"; the same gaps apply
  to the ultra-wide (`ov13b10`).

The sensor driver exposes two modes: 4096x3072 @ 30 fps and 8192x6144 @ 15 fps,
SBGGR10, with exposure / analogue gain / vblank controls.

### Root cause found (2026-11-14, later): the patched libcamera is shadowed

The maintainer already fixed all of the above in a patched libcamera
(`fp6-img/aports/temp/libcamera`, 16 patches + `imx896.yaml`, published as
`libcamera-99990.7.2-r10` in the Catcrafts apk repo): IMX896/OV13B10 helpers and
properties, contrast autofocus, measured black level, CCMs, AWB locus clamp.

The phone has `libcamera-99990.8.0-r1` from the postmarketOS/Nura mirror instead.
pmaports moved its fork to 0.8.0, and `99990.8.0` > `99990.7.2`, so apk prefers the
stock package and the image build silently lost the FP6 camera support. The fork's
patches do not apply to 0.8.0 (`src/ipa/simple` became `src/ipa/softisp`, rebuilt on
libipa), which is presumably why it was not simply bumped.

Port in progress in `libcamera-work/` (branch `fp6-0.8.0-af` of the libcamera
clone, recipe in `libcamera-work/aport`, pkgrel 100 so it outranks pmaports):

- 0003-0006 sensor helpers/properties: applied to 0.8.0 (one trivial conflict).
- 0007-0014 autofocus: ported as one patch; compile-tested only.
- 0015-0016 AWB locus clamp / zone gating: **not ported**; 0.8.0 uses libipa's
  AWB. `imx896.yaml` rewritten for the 0.8.0 format (colourGains instead of
  whitePoints/clampMargin/damping).

## Upstream state

- linux-arm-msm: only Luca Weiss's CCI bus + camera EEPROM series (applied). No
  CAMSS-for-Milos or sensor patches posted; all of that is carried in milos-linux.
- libcamera 0.8.0: no helper, properties or tuning for IMX896 or OV13B10-on-softISP.

## Achievable fixes

A. **Main/ultra-wide image quality (userspace, no kernel flashing).** Add an IMX896
   (and OV13B10) sensor helper + properties to libcamera, write
   `imx896.yaml`/`ov13b10.yaml` tuning (black level, CCM), confirm GPU debayer, and
   set a sane fixed focus (or a simple contrast AF). Upstreamable to libcamera.
B. **Front camera bring-up (kernel).** Cherry-pick `camera-front`, enable
   `CONFIG_VIDEO_CCS=m`, obtain or regenerate the CCS override firmware, RAM-boot,
   test streaming with `v4l2-ctl`/`cam`, then make libcamera accept the CCS sensor.
   Larger and uncertain; the firmware file must come from the maintainer or be
   re-derived.
C. **Ask the maintainer** for the firmware file and current front-camera status
   before doing B.

## Front camera bring-up (2026-11-14, evening) — raw frames working

Approach changed from the maintainer's CCS route to a dedicated driver.

- **Vendor data decoded.** `vendor-blobs/decode_sensormodule.py` reads the CamX
  sensormodule file from the stock `vendor_a` partition
  (`com.qti.sensormodule.tsp_s5kkd1sp_fp6.bin`): a 257-register init sequence and
  six mode tables of 236 registers each, with timings (line/frame length, 30.3 /
  15.1 / 60.1 fps), lane assignment 0x3210, 24 MHz clock.
- **Driver.** `drivers/media/i2c/s5kkd1.c`, generated by
  `vendor-blobs/gen_s5kkd1.py` from the in-tree `s5kjn1.c` skeleton plus those
  tables. Modes: 3104x2336@30, 6208x4672@15, 1920x1080@120; 906 MHz link, 560 MHz
  pixel rate, GRBG. Only 3104x2336 has been run.
- **Two CAMSS bugs found and fixed** (both needed for a sensor on csiphy3 at this
  width):
  1. `camss-csid-340.c`: the PHY select field was GENMASK(21, 20); csiphy3 needs the
     value 4, so it was written as 0 and the CSID listened to nothing. Downstream
     uses a 3-bit mask. Now GENMASK(22, 20).
  2. `camss-vfe.c`: Milos was missing from the 16-byte RDI stride list. 3104-wide
     RAW10 was advertised as 3880 bytes/line while the hardware writes 3888:
     sheared image and IOMMU faults.
- **Ruled out:** D-PHY skew calibration (identical frames with and without it at
  1.8 Gbps/lane) and the downstream always-on camera mux (CPAS TOP 0x1e0/0x1e4
  read 0, i.e. already "main").
- **Verified on the phone** (RAM boot of stock kernel + new DTB, test modules
  loaded by hand): chip ID 0x4841, colour-bar test pattern correct, live frame in
  focus, zero IOMMU faults. `captures/front-testpattern.jpg`, `captures/front-live.jpg`.
- **Not done:** libcamera support (helper, properties, tuning), installing the
  driver/DTB persistently, autofocus actuator (AW86016), other modes, flips,
  rotation value, DT binding document.
- Patches: `for-upstream/kernel/` (4 patches on combined-stable 27825d9f, branch
  `fp6-front-camera` in `milos-linux/`).
- Test loop: `boot/cycle.sh` (reboot → `fastboot boot` → swap modules),
  `boot/front-capture.sh` on the phone, `captures/raw2jpg.py` to view.

## Front camera in libcamera (2026-11-14, night)

- Kernel: `s5kkd1_get_selection()` now answers NATIVE_SIZE, CROP_BOUNDS and
  CROP_DEFAULT with the 6208x4672 pixel array and CROP with each mode's
  analogue crop (read from the mode tables' 0x0344..0x034A: the 1080p mode is
  (1184,1256)/3840x2160). libcamera stops defaulting the array geometry.
- libcamera r103: `0010` sensor helper (gain = code/32, 1x..16x), `0011`
  properties (0.7 um cells, test patterns), `s5kkd1.yaml` (black level 4096,
  grey-world AWB, no CCM yet). With them, AE converges: a 40-frame `cam -c 2`
  capture indoors averages ~92/255; before, frames were black.
- PipeWire lists it (`s5kkd1 [libcamera]`) and GNOME Snapshot uses it as the
  front camera; rotation 270 comes from the DT.
- Left: CCM from the stock tuning data, sensor delays, AW86016 AF driver,
  and the image build carrying the kernel patches.

## Front camera colour from the stock tuning (2026-11-14, night)

- Stock vendor_a sits in `super` (logical partition, one extent at
  5265948672, 1629237248 bytes); mounted read-only on the phone through a
  read-only loop device to copy `com.qti.tuned.tsp_s5kkd1_fp6.bin`
  (sha256 7770f9fd...1f9db10f). Vendor files stay out of the repository.
- `tools/tuned_colour.py` finds CCMs (rows summing to 1) and the AWB
  reference table in a CamX blob; checked against the IMX896 blob, where it
  reproduces the 12 matrices and the locus imx896.yaml was made from.
- S5KKD1 cc13: 4 lux zones (1-200, 230-330, 370-450, 480-999) x 4 CCT
  regions (<2500, 2700-3400, 3700/3800-4300, 4800-10000 K). `s5kkd1.yaml`
  (libcamera r104) carries the bright zone (nodes 2300/3050/4000/6500 K) and
  the 7-point AWB locus (0x8638a), same conventions as imx896.yaml.
- Verified: the GPU debayer receives the interpolated CCM (identity before);
  mean saturation 58.6 -> 120.1 on the same scene. Only tested in a dark
  room, where the bright-zone matrices also raise chroma noise; check in
  daylight.
