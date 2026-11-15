#!/bin/bash
# Host side: reboot the phone to the bootloader, RAM-boot an image (fastboot boot ONLY,
# never flash), then swap in the test camss module and load the sensor drivers.
# usage: cycle.sh [image]   (default boot/test-s5kkd1.img)
cd "$(dirname "$0")"
IMG=${1:-test-s5kkd1.img}
P=user@172.16.42.1
# macOS has no timeout(1): gtimeout (brew coreutils) or a perl alarm instead
command -v timeout >/dev/null 2>&1 || timeout() {
	if command -v gtimeout >/dev/null 2>&1; then gtimeout "$@"
	else local t=$1; shift; perl -e 'alarm shift; exec @ARGV or die "exec: $!"' "$t" "$@"; fi
}
ssh -o BatchMode=yes -o ConnectTimeout=8 $P 'sync; sudo systemctl reboot --reboot-argument=bootloader' 2>/dev/null
for i in $(seq 1 40); do sleep 3; D=$(fastboot devices 2>/dev/null || true); [ -n "$D" ] && break; done
[ -n "$D" ] || { echo "no fastboot device"; exit 1; }
O=$(timeout 90 fastboot boot "$IMG" 2>&1 || true); echo "$O" | tail -1
for i in $(seq 1 50); do sleep 3; ssh -o BatchMode=yes -o ConnectTimeout=3 $P true 2>/dev/null && break; done
sleep 15
ssh -o BatchMode=yes -o ConnectTimeout=8 $P '
systemctl --user stop pipewire.socket pipewire-pulse.socket wireplumber pipewire pipewire-pulse 2>/dev/null; sleep 1
sudo rmmod qcom_camss && sudo insmod ~/fp6-test/qcom-camss.ko && echo "test camss loaded"
sudo insmod ~/fp6-test/s5kkd1.ko && echo "s5kkd1 loaded"
sleep 2; sudo media-ctl -d /dev/media0 -p | grep -c "entity.*\(s5k\|imx\|ov13\)"
systemctl --user start pipewire.socket pipewire-pulse.socket wireplumber'
