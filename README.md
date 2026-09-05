# fp6-img

Flashable [postmarketOS](https://postmarketos.org/) images for the
**Fairphone 6/6+**, built nightly from the
[Catcrafts milos-linux](https://forgejo.catcrafts.net/Catcrafts/milos-linux)
`combined-stable` kernel branch, with
[imsd](https://forgejo.catcrafts.net/Catcrafts/imsd) (userspace VoLTE)
preinstalled.

Maintained by [Jorijn van der Graaf](https://catcrafts.net/about)
(TheMightyCat) at [Catcrafts](https://catcrafts.net/).

## What works

Everything on the `combined-stable` branch: display, touch, wifi, cellular
data, NFC (reader), speaker audio, microphone, IMU, magnetometer, barometer,
ambient light/proximity, fingerprint unlock through
[fingerprintd](https://forgejo.catcrafts.net/Catcrafts/fingerprintd), plus
VoLTE calls (both directions) through imsd.

## Flashing

Download `fp6-img.tar.xz` from the latest release and unlock the bootloader
([Fairphone's official process](https://support.fairphone.com/hc/en-us/articles/10492476238737)).

**Install**: with the phone in fastboot mode,

```sh
tar xf fp6-img.tar.xz
cd fp6-img
./install.sh
```

`install.sh` erases dtbo, flashes the rootfs, **RAM-boots** the kernel, writes the boot partition from
inside Linux where the bootloader's NV-wipe cannot see it, then reads the modem
NV back and reports the result. The bootloader never writes `boot`.

Default login: `user` / `147147` (same as official postmarketOS images —
change it). **Never re-lock the bootloader** with a custom image installed.

## VoLTE configuration

imsd is installed but needs your carrier's P-CSCF address:

```sh
# /etc/imsd.env
PCSCF=<your carrier's P-CSCF IPv6 address>
```

Find it in a stock-firmware capture or your carrier's IMS documentation, then
`systemctl restart imsd` (the service is enabled at boot and waits for this
file to exist). See the
[imsd README](https://forgejo.catcrafts.net/Catcrafts/imsd) for the full
variable reference and carrier assumptions.

## Fingerprint

Enrol under **Settings → Users** (Plasma's own fingerprint page; the `fprintd`
command-line tools are not installed, fingerprintd replaces that package).
**Hold** the finger on the sensor for each of the ~20 presses rather than
tapping it; a held press is what the matcher was measured on.

Two things to know:

- The lock screen listens for a finger for **60 seconds after it appears**.
  A press after that reaches nothing and looks like a dead sensor. Lock and
  unlock again to re-arm it.
- The matcher is the phone's own proprietary trustlet, reassembled from the
  stock modem partition on first boot and never shipped by us. Templates are
  stored on the Android `persist` partition, sealed to the same hardware
  anti-rollback counter stock Android uses. Whether fingerprints enrolled under
  stock Android survive a return to it after using this has **not** been
  tested.

A finger can also run something in your session on a match
(`~/.config/fingerprintd/fingers.conf`, see the fingerprintd README).
