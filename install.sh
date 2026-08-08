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
fastboot devices 2>/dev/null | grep -q fastboot || \
	die "no device in fastboot mode (Vol-down + Power, USB connected)"

cat <<'EOF'
This will REPLACE the operating system on the connected Fairphone 6
(userdata + boot). The modem's NV storage is preserved - that is the point
of this installer. Press Enter to continue, Ctrl-C to abort.
EOF
read -r _

# --- 1+2: safe fastboot writes -------------------------------------------------
say "erasing dtbo (one-time; safe - does not touch modem NV)"
fastboot erase dtbo

say "flashing rootfs to userdata (this is the big one, be patient)"
fastboot flash userdata "$ROOTFS"

# --- 3: RAM-boot the kernel, no write -----------------------------------------
say "RAM-booting the new system (nothing is written)"
fastboot boot "$BOOT"

say "waiting for the phone to come up on the USB network ($PHONE)"
i=0
until (exec 3<>"/dev/tcp/$PHONE/22") 2>/dev/null; do
	i=$((i+1)); [ $i -gt 40 ] && die "phone did not appear on $PHONE after 400s"
	sleep 10
done
exec 3<&- 3>&- 2>/dev/null || true
sleep 8

# --- 4: write boot from Linux ---------------------------------------------------
say "writing boot.img to boot_a from inside Linux (password: 147147)"
cat <<'EOF'
You will be asked for a password up to twice (ssh login, then sudo).
On a fresh image both are: 147147
EOF
SSHOPTS="-o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=/dev/null"
# shellcheck disable=SC2086
cat "$BOOT" | ssh $SSHOPTS "user@$PHONE" \
	'sudo dd of=/dev/disk/by-partlabel/boot_a bs=1M conv=fsync status=none && sync && echo BOOT-WRITTEN'

say "verifying modem NV survived"
# shellcheck disable=SC2086
Z=$(ssh $SSHOPTS "user@$PHONE" \
	'sudo od -An -tx1 -N4096 /dev/disk/by-partlabel/modemst1 | sort -u | wc -l' 2>/dev/null || echo 0)
if [ "$Z" -gt 2 ]; then
	echo "modem NV intact - cellular will work."
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
	'sudo setsid sh -c "sleep 2; /sbin/reboot" </dev/null >/dev/null 2>&1 & sleep 5' || true

cat <<'EOF'

DONE. The phone reboots into postmarketOS from its own boot partition.
Log in as user / 147147 (change it!). For VoLTE, write your carrier's
P-CSCF into /etc/imsd.env and restart imsd - see the README.
EOF
