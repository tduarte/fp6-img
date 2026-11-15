# Fairphone 6 on Catcrafts Nura (Phosh) — hardware status pass

2026-11-14, kernel 7.3.0 `combined-stable` @ 27825d9f, image of 2026-11-10.
Read-only checks over SSH (driver state, logs, service state). "Present" means the
driver and device are up; it does not mean a full functional test was done.

| Area | State | Evidence / note |
|---|---|---|
| Main camera (IMX896) | Works with patched libcamera r100 | sensor helper, tuning, autofocus confirmed with `cam`; stock libcamera gives near-black frames |
| Ultra-wide (OV13B10) | Present, untested after patch | no `ov13b10.yaml`, falls back to uncalibrated tuning |
| Front camera (S5KKD1SP) | Not working | no DT node, `CONFIG_VIDEO_CCS` off, CCS firmware not public |
| ToF ranger (VL53L3) | Not working | DT node present, no driver bound |
| Camera flash LED | Present | `white:flash` LED registered; not exposed by libcamera |
| GPU zero-copy for camera | Not working | "Importing input DMABuf failed, falling back to upload" |
| Wi-Fi | Works | `wlan0` associated and connected |
| Bluetooth | Present, scanning works | controller powered, firmware loaded, devices discovered; pairing/audio untested |
| Modem | Present, untested | IMEI and firmware read fine; state `failed: sim-missing` (no SIM inserted) |
| GPS | Unknown | ModemManager reports gps-raw/nmea capability; no `/dev/gnss*`; needs a test with location enabled |
| Speakers, microphone | Present | one sink (stereo AW88261), one source (handset mic) |
| Headset / USB-C audio | Not present | no other sinks or sources |
| NFC | Present | `nfc0` registered (README: reader mode only) |
| IMU, magnetometer, barometer, light/proximity | Present | all five IIO devices registered |
| Proximity/light (STK) reliability | Intermittent errors | `stk3310 7-0048: register read failed` (I2C NAK), 3 times in 35 min |
| Touchscreen | Works, intermittent errors | `eswin_eph8621: SPI transfer timed out` + GPI DMA `CH STOP` timeouts, twice in 35 min |
| Hardware video codec (Iris) | Present, apps unlikely to use it | decoder/encoder V4L2 nodes exist; no GStreamer v4l2 decoder elements found |
| Display / GPU | Works | Adreno 810 via Mesa 26.2.6; one `no encoder found for crtc 0` error per screen blank |
| USB-C display output | Not present | only `DSI-1` connector exists |
| USB-C charging / role | Works | UCSI port and partner registered, battery charging |
| Wireless charging | Unknown | power supply node exists, not tested |
| Suspend | Untested | `deep` and `s2idle` offered; zero suspend cycles since boot (USB was attached) |
| Fingerprint | Service active | `fingerprintd` active |
| VoLTE (imsd) | Inactive | no SIM, so expected |
| systemd failed units | None | system and user |

## Candidates for follow-up work, roughly by value

1. Front camera bring-up (kernel + CCS firmware + libcamera support).
2. Ultra-wide tuning file (`ov13b10.yaml`) and a Snapshot check of both rear cameras.
3. Touchscreen SPI/GPI timeouts (kernel, intermittent input loss).
4. Proximity sensor I2C NAKs.
5. Camera DMABuf import on the GPU path (performance).
6. Suspend/battery-life test on battery, GPS test, Bluetooth audio test, calls with a SIM.
7. VL53L3 ToF driver, USB-C DisplayPort alt mode.
