#!/bin/sh -eu
# fp6-img modem-preserving installer for the Fairphone 6.
#
# Why this exists: this device's bootloader ZEROES the modem's NV storage
# (modemst1/modemst2) whenever the boot partition is written over fastboot —
# after a classic `fastboot flash boot`, cellular (incl. eSIM access) is dead
# until restored. Isolated by experiment, 2026-08-09 (fp6 journal/modem).
#
# This installer never lets the bootloader write boot:
#   1. fastboot erase dtbo          (verified safe)
#   2. fastboot flash userdata      (rootfs; not a boot write - believed safe,
#                                    final isolation pending; step 5 verifies)
#   3. fastboot boot boot.img       (RAM boot - writes nothing; verified safe)
#   4. dd boot.img to boot_a from the booted Linux over USB networking
#      (kernel block layer - the bootloader never sees it)
#   5. read back the modem NV and tell you the truth either way
#
# Requirements on this machine: fastboot, ssh. Phone: bootloader unlocked,
# in fastboot mode (Vol-down + Power), connected over USB.
# Run from a directory containing boot.img and fairphone-fp6.img.

PHONE=172.16.42.1
BOOT=${BOOT:-boot.img}
ROOTFS=${ROOTFS:-fairphone-fp6.img}

say() { printf '\n== %s ==\n' "$*"; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

# --- preflight ---------------------------------------------------------------
command -v fastboot >/dev/null || die "fastboot not found (install android-tools)"
command -v ssh >/dev/null || die "ssh not found"
[ -f "$BOOT" ] || die "$BOOT not found (download it from the release)"
[ -f "$ROOTFS" ] || die "$ROOTFS not found (download it from the release)"
# NEVER pipe fastboot into grep -q or anything that exits early: the reader
# quitting mid-output SIGPIPEs fastboot to death mid-transaction and leaves
# the bootloader's fastboot state machine wedged - the NEXT command then
# hangs. Capture completely, test afterwards.
DEVICES=$(fastboot devices 2>/dev/null || true)
printf '%s' "$DEVICES" | grep -q fastboot || \
	die "no device in fastboot mode (Vol-down + Power, USB connected)"
DEVINFO=$(timeout 20 fastboot oem device-info 2>&1 || true)
printf '%s' "$DEVINFO" | grep -q "Device unlocked: true" || \
	die "bootloader is LOCKED - nothing was changed. Unlock it first (OEM
       unlocking in Android developer settings + Fairphone's unlock code:
       https://support.fairphone.com/hc/en-us/articles/10492476238737),
       then re-run. Note that unlocking wipes the phone."

cat <<'EOF'
This will replace the operating system on the connected Fairphone 6 with catcrafts patched postmarketos. Keep the phone connected on USB for the entirety of this script's duration. 
If this has been usefull please consider donating at https://bunq.me/catcrafts
WARNING: This is a early version of the install script for power users ahead of the official release, while tested this has not been trough the strict quality control the offical release will have.
Press Enter to continue, Ctrl-C to abort.
EOF
read -r _

# --- 1+2: safe fastboot writes -------------------------------------------------
say "erasing dtbo"
fastboot erase dtbo

say "flashing rootfs to userdata"
fastboot flash userdata "$ROOTFS"

# --- 3: RAM-boot the kernel, no write -----------------------------------------
say "RAM-booting the new system"
fastboot boot "$BOOT"

say "waiting for the phone to come up on the USB network ($PHONE)"
# The phone side is reliable (it always configures 172.16.42.1 on its USB
# gadget); when this step times out the problem is almost always THIS
# machine's side of the USB link: the gadget shows up as a new network
# interface here, and either nothing configures an address on it, or a
# network manager grabs it with the wrong profile (we have seen
# NetworkManager hand it an unrelated LAN address). The phone runs a DHCP
# server on the link, but host managers don't always ask.
i=0
until (exec 3<>"/dev/tcp/$PHONE/22") 2>/dev/null; do
	i=$((i+1))
	if [ $i -gt 40 ]; then
		cat >&2 <<'EOF'
ERROR: phone did not appear on 172.16.42.1 after 400s.

The phone has most likely booted fine - this machine just hasn't configured
its side of the USB network link. Fix it by hand:

  1. find the new interface:   ip link   (usually enp*u* or usb0, appeared
     when the phone booted; unplug/replug USB and watch if unsure)
  2. give this machine an address on it:
        sudo ip link set <iface> up
        sudo ip addr add 172.16.42.2/24 dev <iface>
  3. verify:                   ping 172.16.42.1
  4. re-run this script - every step is safe to repeat.

If a network manager keeps reclaiming the interface, tell it to ignore it,
e.g.: sudo nmcli device set <iface> managed no
EOF
		exit 1
	fi
	sleep 10
done
exec 3<&- 3>&- 2>/dev/null || true
sleep 8

# --- 4: write boot from Linux ---------------------------------------------------
# One authenticated ssh connection is opened and kept alive (ControlMaster);
# sudo self-answers with the image's default password via an askpass helper
# (sudo -S would eat the first bytes of the boot image from stdin).
PW=147147
CTL="/tmp/fp6-install-ssh-$$"
SSHOPTS="-o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=/dev/null \
	-o ControlMaster=auto -o ControlPath=$CTL -o ControlPersist=120"
SUDO="SUDO_ASKPASS=/tmp/.fp6-install-pw sudo -A"

# ssh refuses to read a password from stdin (it wants the terminal), but
# OpenSSH >= 8.4 honors an askpass helper even with a terminal attached via
# SSH_ASKPASS_REQUIRE=force - so the known fresh-image password answers
# itself. On older OpenSSH this falls back to one interactive prompt.
ASKPASS=$(mktemp)
printf '#!/bin/sh\necho %s\n' "$PW" > "$ASKPASS"
chmod 700 "$ASKPASS"
trap 'rm -f "$ASKPASS"' EXIT
export SSH_ASKPASS="$ASKPASS" SSH_ASKPASS_REQUIRE=force DISPLAY="${DISPLAY:-:0}"

say "connecting"
# shellcheck disable=SC2086
ssh $SSHOPTS "user@$PHONE" \
	"printf '#!/bin/sh\necho $PW\n' > /tmp/.fp6-install-pw && chmod 700 /tmp/.fp6-install-pw && echo CONNECTED" \
	|| die "could not connect to the phone"

say "writing boot.img to boot_a"
# shellcheck disable=SC2086
cat "$BOOT" | ssh $SSHOPTS "user@$PHONE" \
	"$SUDO dd of=/dev/disk/by-partlabel/boot_a bs=1M conv=fsync status=none && sync && echo BOOT-WRITTEN"

# shellcheck disable=SC2086
Z=$(ssh $SSHOPTS "user@$PHONE" \
	"$SUDO od -An -tx1 -N4096 /dev/disk/by-partlabel/modemst1 | sort -u | wc -l" 2>/dev/null || echo 0)
if [ "$Z" -gt 2 ]; then
	echo "modem NV intact."
else
	cat <<'EOF'
WARNING: the modem NV reads empty. If this device previously ran stock
Android, its factory copy (fsg) is still on the device but postmarketOS
cannot restore from it yet - see the README's modem section. If you have a
modemst backup, dd it back now.
EOF
fi

say "rebooting into the installed system"
# shellcheck disable=SC2086
ssh $SSHOPTS "user@$PHONE" \
	"$SUDO setsid sh -c 'sleep 2; /sbin/reboot' </dev/null >/dev/null 2>&1 & sleep 5" || true
# shellcheck disable=SC2086
ssh $SSHOPTS -O exit "user@$PHONE" 2>/dev/null || true

cat <<'EOF'

DONE. The phone reboots into postmarketOS from its own boot partition.
Log in as user / 147147. For VoLTE, write your carrier's
P-CSCF into /etc/imsd.env and restart imsd - see the README.
EOF
