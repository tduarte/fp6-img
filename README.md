# fp6-img

Flashable [Nura](https://nura.eco) images for the
**Fairphone 6/6+**, built from the
[Catcrafts milos-linux](https://forgejo.catcrafts.net/Catcrafts/milos-linux)
`combined-stable` kernel branch.

Maintained by [Jorijn van der Graaf](https://catcrafts.net/about)
(TheMightyCat) at [Catcrafts](https://catcrafts.net/).

## What works

Everything on the `combined-stable` branch: display, touch, wifi, cellular
data, NFC (reader), speaker audio, microphone, IMU, magnetometer, barometer,
ambient light/proximity, fingerprint unlock through
[fingerprintd](https://forgejo.catcrafts.net/Catcrafts/fingerprintd), plus
VoLTE calls (both directions) through [imsd](https://forgejo.catcrafts.net/Catcrafts/imsd).

## Flashing

Download `fp6-img-{DE}.tar.xz` with your preferred DE from the
[`latest` release](https://forgejo.catcrafts.net/Catcrafts/fp6-img/releases/tag/latest)
(`{DE}` is `plasma` for Plasma Mobile, calls through Plasma Dialer, or `phosh` for
Phosh, calls through GNOME Calls) and unlock the bootloader
([Fairphone's official process](https://support.fairphone.com/hc/en-us/articles/10492476238737)).

**Install**: with the phone in fastboot mode,

```sh
tar xf fp6-img-{DE}.tar.xz
cd fp6-img-{DE}
./install.sh
```

`install.sh` erases dtbo, flashes the rootfs, **RAM-boots** the kernel, writes the boot partition from
inside Linux where the bootloader's NV-wipe cannot see it, then reads the modem
NV back and reports the result. The bootloader never writes `boot`.

Default login: `user` / `147147` (same as official Nura images). 
**Never re-lock the bootloader** with a custom image installed.

## License

GPL-3.0-only - see [LICENSE](LICENSE). That covers our own code; patches and packaging carried from other projects keep the license named in their files.

## Funding

https://catcrafts.net/shop/donation - see [FUNDING](FUNDING.yml)

## Copyright

Copyright (C) 2026 Catcrafts® [catcrafts.net](https://catcrafts.net/)
