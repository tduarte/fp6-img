#!/bin/sh
# Build a RAM-boot test image: the stock kernel and ramdisk of a released
# boot.img with only the device tree replaced. Boot it with `fastboot boot`
# (never `fastboot flash boot` on this phone: it wipes the modem NV).
# usage: mk-test-bootimg.sh <released boot.img> <new .dtb> <out.img>
# needs unpack_bootimg and mkbootimg (android-tools)
set -eu
SRC=$1; DTB=$2; OUT=$3
T=$(mktemp -d)
ARGS=$(unpack_bootimg --boot_img "$SRC" --out "$T" --format=mkbootimg)
ARGS=$(printf '%s' "$ARGS" | sed "s#--dtb $T/dtb#--dtb $DTB#")
eval "mkbootimg $ARGS -o '$OUT'"
rm -rf "$T"
ls -la "$OUT"
