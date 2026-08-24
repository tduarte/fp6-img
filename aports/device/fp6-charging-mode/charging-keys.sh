#!/bin/sh
# Charging-mode key handler (r4):
#   volume-down (pmic_resin) -> enable ssh debug mode (inhibits suspend)
#   volume-up   (gpio-keys)  -> toggle the on-screen battery status display
# The display costs nothing while off: panel + pipeline stay powered down
# and suspend cycling continues. While visible, /run/charging-mode-display
# inhibits suspend (the monitor checks it); toggling off (or the safety
# timeout) blanks everything again and cycling resumes.
# The power key is taken (logind: reboot to normal boot).

log() { echo "charging-keys: $*"; }

BAT=/sys/class/power_supply/qcom-battmgr-bat
USB=/sys/class/power_supply/qcom-battmgr-usb
DISPLAY_MARKER=/run/charging-mode-display
DISPLAY_TIMEOUT=600   # safety auto-off, seconds

find_dev() {
    for e in /sys/class/input/event*; do
        n=$(cat "$e/device/name" 2>/dev/null)
        case "$n" in
        $1) echo "/dev/input/${e##*/}"; return 0 ;;
        esac
    done
    return 1
}

read_key() {
    # echoes the key code of a key RELEASE event (or nothing). Release, not
    # press: when a key wakes the phone from suspend, the press can be
    # consumed as the wake event while the release is still delivered — so
    # triggering on release works both awake and as a wake key.
    # input_event on arm64: u64 sec, u64 usec, u16 type, u16 code, s32 value
    # od -tu2 words: 1-8 time, 9 type, 10 code, 11-12 value (lo, hi)
    _d="$1"
    set -- $(dd if="$_d" bs=24 count=1 2>/dev/null | od -An -v -tu2)
    [ $# -ge 11 ] || return 1
    [ "$9" = "1" ] && [ "${11}" = "0" ] && echo "${10}"
    return 0
}

enable_ssh() {
    [ -e /run/charging-mode-ssh ] && return
    : > /run/charging-mode-ssh
    log "volume-down pressed: enabling usbnet+sshd, suspend cycling inhibited"
    systemctl start systemd-user-sessions.service charging-usbnet.service sshd.service
}

draw_status() {
    cap=$(cat "$BAT/capacity" 2>/dev/null)
    cur=$(cat "$BAT/current_now" 2>/dev/null)
    cc=$(cat "$BAT/charge_counter" 2>/dev/null)
    full=$(cat "$BAT/charge_full" 2>/dev/null)
    [ -n "$full" ] || full=4415000
    uv=$(cat "$USB/voltage_now" 2>/dev/null)
    ui=$(cat "$USB/current_now" 2>/dev/null)
    eta=$(awk -v f="$full" -v c="$cc" -v i="$cur" 'BEGIN {
        if (i > 10000) { h = (f - c) / i; printf "%dh%02dm", int(h), (h - int(h)) * 60 }
        else printf "--"
    }' 2>/dev/null)
    {
        printf '\033[2J\033[H\n\n'
        printf '   CHARGING  %s%%\n\n' "$cap"
        printf '   battery  %d mA\n' "$(( ${cur:-0} / 1000 ))"
        printf '   input    %d mV  %d mA\n' "$(( ${uv:-0} / 1000 ))" "$(( ${ui:-0} / 1000 ))"
        printf '   full in  %s\n' "$eta"
    } > /dev/tty0 2>/dev/null
}

display_off() {
    rm -f "$DISPLAY_MARKER"
    printf '\033[2J\033[H' > /dev/tty0 2>/dev/null
    for b in /sys/class/backlight/*/brightness; do echo 0 > "$b" 2>/dev/null; done
    for f in /sys/class/graphics/fb*/blank; do { echo 4 > "$f" || echo 1 > "$f"; } 2>/dev/null; done
    log "status display OFF"
}

display_on() {
    : > "$DISPLAY_MARKER"
    log "volume-up pressed: status display ON"
    for f in /sys/class/graphics/fb*/blank; do echo 0 > "$f" 2>/dev/null; done
    for b in /sys/class/backlight/*/brightness; do echo 400 > "$b" 2>/dev/null; done
    (
        shown=0
        while [ -e "$DISPLAY_MARKER" ] && [ "$shown" -lt "$DISPLAY_TIMEOUT" ]; do
            draw_status
            sleep 5
            shown=$((shown + 5))
        done
        display_off
    ) &
}

VOLDOWN_DEV=$(find_dev "*resin*")
VOLUP_DEV=$(find_dev "gpio-keys")

[ -n "$VOLDOWN_DEV" ] && log "volume-down (ssh) on $VOLDOWN_DEV" \
    || log "no resin device - ssh enable unavailable this boot"
[ -n "$VOLUP_DEV" ] && log "volume-up (display) on $VOLUP_DEV" \
    || log "no gpio-keys device - status display unavailable this boot"

if [ -n "$VOLDOWN_DEV" ]; then
    ( while :; do [ "$(read_key "$VOLDOWN_DEV")" = "114" ] && enable_ssh; done ) &
fi
if [ -n "$VOLUP_DEV" ]; then
    ( while :; do
        [ "$(read_key "$VOLUP_DEV")" = "115" ] || continue
        if [ -e "$DISPLAY_MARKER" ]; then display_off; else display_on; fi
    done ) &
fi
wait
