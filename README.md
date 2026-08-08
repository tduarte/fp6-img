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
> against a live network.

## What works

Everything on the `combined-stable` branch: display, touch, wifi, cellular
data, NFC (reader), speaker audio, microphone, IMU, magnetometer, barometer,
ambient light/proximity — plus VoLTE calls (both directions) through imsd.

Verified on exactly one device / one carrier (KPN NL). Reports from other
carriers are very welcome.

## Flashing

Download `boot.img` and `fairphone-fp6.img` from the latest release, unlock
the bootloader ([Fairphone's official process](https://support.fairphone.com/hc/en-us/articles/10492476238737)),
then:

```sh
fastboot flash userdata fairphone-fp6.img
fastboot flash boot boot.img
fastboot erase dtbo
fastboot reboot
```

Default login: `user` / `147147` (same as official postmarketOS images —
change it). **Never re-lock the bootloader** with a custom image installed.

> [!WARNING]
> **Back up your modem's NV partitions before flashing.** Flash sessions have
> been observed to zero `modemst1`/`modemst2` on this device, after which the
> modem reports no IMEI and neither SIM slot answers (`no-atr-received`) —
> including the eSIM. The profiles themselves are safe in the eUICC, but only
> a restore of working `modemst` images brings access back; stock Android
> re-provisions them on boot, postmarketOS cannot. Before your first flash:
> `dd` both partitions to files from a rooted stock system (or from a running
> pmOS: `/dev/disk/by-partlabel/modemst1` and `modemst2`) and keep them
> forever. Restore with `dd` in the other direction, then reboot.

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

- [x] End-to-end pipeline validation (first complete image built 2026-08-08)
- [x] Speaker-audio userspace files (`soc-fairphone-fp6-audio`: topology,
      amp config, UCM — byte-identical to the tested dev-phone set; blob
      provenance to be settled before this repo goes public)
- [x] imsd in the image (pinned to the public 0.3.0 commit; the phone's
      working call stack incl. callaudioshim and the modem-daemon autostart
      override ship as packages)
- [ ] Nightly schedule once the first dispatched run is green
