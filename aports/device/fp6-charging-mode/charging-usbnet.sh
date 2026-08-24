#!/bin/sh
# Give the USB gadget interface its usual static address (the one the NM
# "Developer Mode" profile would assign) without NetworkManager. The
# workstation side self-configures 172.16.42.2 via its udev rule, so
# `ssh fp6usb4` works in charging mode.

IF=""
for i in $(seq 1 30); do
    IF=$(ls /sys/class/net 2>/dev/null | grep '^usb' | head -1)
    [ -n "$IF" ] && break
    sleep 1
done
[ -n "$IF" ] || exit 0

ip addr replace 172.16.42.1/16 dev "$IF"
ip link set "$IF" up
