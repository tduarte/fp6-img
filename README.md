# fp6-img

Flashable [postmarketOS](https://postmarketos.org/) images for the
**Fairphone 6**, built nightly from the
[Catcrafts milos-linux](https://forgejo.catcrafts.net/Catcrafts/milos-linux)
`combined-stable` kernel branch, with
[imsd](https://forgejo.catcrafts.net/Catcrafts/imsd) (userspace VoLTE)
preinstalled.

Maintained by [Jorijn van der Graaf](https://catcrafts.net/about)
(TheMightyCat) at [Catcrafts](https://catcrafts.net/).

> [!CAUTION]
> **Emergency calling is unverified.** Calls (including 112/911) go through
> imsd, whose emergency path is spec-shaped but has never been verified
> against a live network. There is also a known kernel bug that can wedge the
> modem data path until reboot. **Do not rely on a phone running this image
> to make emergency calls.**

## What works

Everything on the `combined-stable` branch: display, touch, wifi, cellular
data, NFC (reader), speaker audio, microphone, IMU, magnetometer, barometer,
ambient light/proximity — plus VoLTE calls (both directions) through imsd.

Verified on exactly one device / one carrier (KPN NL). Reports from other
carriers are very welcome.

## Flashing

Download `fp6-boot.img` and the rootfs image from the latest release, unlock
the bootloader ([Fairphone's official process](https://support.fairphone.com/hc/en-us/articles/10492476238737)),
then:

```sh
fastboot flash userdata fairphone-fp6.img
fastboot flash boot fp6-boot.img
fastboot reboot
```

Default login: `user` / `147147` (same as official postmarketOS images —
change it). **Never re-lock the bootloader** with a custom image installed.

## VoLTE configuration

imsd is installed but needs your carrier's P-CSCF address:

```sh
# /etc/imsd.env
PCSCF=<your carrier's P-CSCF IPv6 address>
```

Find it in a stock-firmware capture or your carrier's IMS documentation, then
`systemctl restart imsd`. See the
[imsd README](https://forgejo.catcrafts.net/Catcrafts/imsd) for the full
variable reference and carrier assumptions.

## How it builds

`build.sh` drives [pmbootstrap](https://gitlab.postmarketos.org/postmarketOS/pmbootstrap)
with the `aports/` overlay in this repository:

- `device/linux-postmarketos-qcom-milos` — the pmaports kernel aport,
  repointed at `combined-stable` (source tarball generated with git-archive;
  the Forgejo instance serves no source archives) with the exact kernel
  config the development FP6 runs.
- `modem/imsd` — imsd, packaged from source. Its `provides=81voltd` keeps the
  conflicting modem-firmware IMS helper off the image (two IMS stacks cannot
  share one PDN).
- `main/postmarketos-config-nftables` — adds the `-imsd` subpackage accepting
  imsd's IPsec-protected SIP ports on the IMS PDN (auto-installed alongside
  imsd).

## Roadmap

- [ ] End-to-end pipeline validation (`build.sh` has TODO(validate) markers)
- [ ] Speaker-audio userspace files (AudioReach topology + UCM; firmware
      redistribution being sorted out)
- [ ] imsd 0.3.0 tag (aport currently needs it published)
- [ ] Nightly schedule once the first dispatched run is green
