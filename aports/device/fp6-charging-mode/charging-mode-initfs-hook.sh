#!/bin/sh
# FP6 offline charging (work/charging-mode): on charger-triggered boots,
# kill the boot splash and panel as early as software can — this hook runs
# right after splash_start in the initramfs (~6-10 s after power-on), vs
# the charging monitor's blank at ~16-20 s. The 0-5 s bootloader logo is
# ABL's and untouchable. Executed via `sh` by run_hooks (subshell, exit is
# safe); written to fall through harmlessly on any failure — a normal boot
# must never be affected.

if grep -Eq '(^| )androidboot\.mode=charger( |$)' /proc/cmdline 2>/dev/null; then
    command -v plymouth >/dev/null 2>&1 && plymouth quit 2>/dev/null
    for b in /sys/class/backlight/*/brightness; do
        [ -w "$b" ] && echo 0 > "$b" 2>/dev/null
    done
    for f in /sys/class/graphics/fb*/blank; do
        [ -w "$f" ] && { echo 4 > "$f" || echo 1 > "$f"; } 2>/dev/null
    done
fi
exit 0
