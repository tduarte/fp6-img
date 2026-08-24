#!/bin/sh
# Offline charging monitor (prototype r3). Runs only inside charging.target.
#
# - waits for the ADSP-backed battmgr supplies (charging + USB-PD live on
#   the ADSP, which never sleeps — AP suspend does not touch the PD contract)
# - blanks + powers down the display pipeline, stops modem/cdsp remoteprocs,
#   caps CPU frequency, nudges UFS auto-hibernate
# - unplug -> orderly poweroff (debounced ~6 s; a poweroff while plugged
#   re-wakes via the USB_CHARGER PON trigger)
# - power key -> logind reboots to a NORMAL boot (generator drop-in)
# - suspend cycling (rock-bottom mode): only when /etc/charging-mode/
#   enable-suspend exists AND ssh debug mode is off (/run/charging-mode-ssh,
#   volume-down) AND the status display is off (/run/charging-mode-display,
#   volume-up toggle). Arms an RTC wakealarm before every suspend and never
#   suspends without a verified alarm.
#
# Deliberately NO rfkill anywhere: systemd-rfkill would persist a soft-block
# into normal boots (the 2026-08-23 wifi trap).
#
# Failsafe: if battmgr never appears, reboot — that PONs as HARD_RESET, so
# the phone comes back in a NORMAL boot and is never stuck dark.

BAT=/sys/class/power_supply/qcom-battmgr-bat
USB=/sys/class/power_supply/qcom-battmgr-usb
WAKEALARM=/sys/class/rtc/rtc0/wakealarm
SUSPEND_SECS=45

log() { echo "charging-monitor: $*"; }

log "offline charging mode active (prototype r5)"

i=0
while [ ! -r "$USB/online" ]; do
    i=$((i + 1))
    if [ "$i" -gt 180 ]; then
        log "battmgr never appeared after ${i}s - failsafe reboot to normal boot"
        exec systemctl reboot
    fi
    sleep 1
done
log "battmgr up after ${i}s"

for b in /sys/class/backlight/*/brightness; do
    [ -w "$b" ] && echo 0 > "$b" 2>/dev/null
done
log "panel blanked"

# release the boot splash and power the display pipeline down (best effort —
# brightness 0 alone leaves the DSI/DPU scanning out a black frame)
if command -v plymouth >/dev/null 2>&1 && plymouth --ping 2>/dev/null; then
    plymouth quit 2>/dev/null && log "plymouth quit"
fi
for f in /sys/class/graphics/fb*/blank; do
    [ -w "$f" ] || continue
    { echo 4 > "$f" || echo 1 > "$f"; } 2>/dev/null && log "fb powerdown via $f"
done

# radios/compute are pointless while charging — stop modem and cdsp
# remoteprocs (adsp stays: it IS the charger; wpss left alone near the
# WCN-combo trap). The stop write can block past a short timeout yet still
# succeed — judge by the resulting state, not the write's exit code.
for r in /sys/class/remoteproc/remoteproc*; do
    name=$(cat "$r/name" 2>/dev/null)
    case "$name" in
    *mpss*|*modem*|*mss*|*cdsp*)
        timeout 25 sh -c "echo stop > '$r/state'" 2>/dev/null
        if [ "$(cat "$r/state" 2>/dev/null)" = "offline" ]; then
            log "stopped remoteproc $name"
        else
            log "remoteproc $name did not stop (state=$(cat "$r/state" 2>/dev/null)) - continuing"
        fi
        ;;
    esac
done

# cap CPU frequency to the minimum, then offline every core except cpu0
# (a little @ 441.6 MHz) — emptying the two big clusters (cpu4-6, cpu7)
# lets their cluster rails power-collapse entirely. Charging mode always
# ends in a reboot, so no undo needed.
for p in /sys/devices/system/cpu/cpufreq/policy*; do
    cat "$p/cpuinfo_min_freq" > "$p/scaling_max_freq" 2>/dev/null
done
for c in /sys/devices/system/cpu/cpu[1-9]*; do
    [ -w "$c/online" ] && echo 0 > "$c/online" 2>/dev/null
done
log "cpu freq capped to min, online cpus: $(cat /sys/devices/system/cpu/online 2>/dev/null)"
# NOTE: do NOT touch UFS auto_hibern8 — the 2026-08-24 PD-boot crash
# (ufshcd hibern8 exit failed, dead rootfs at t=34s) happened with our
# auto_hibern8=5000 write + suspend-thrash; the write is the prime suspect
# and its benefit was never measured.

# battmgr power_supply events are wakeup sources, and a PPS charger streams
# telemetry ~1/s — that turned suspend cycling into 1.2 s suspend-thrash on
# the PD brick. Drop the psy wakeup flags: the RTC alarm is our only
# intended waker (unplug is then detected at the next wake, <=45 s).
for w in /sys/class/power_supply/qcom-battmgr-*/device/power/wakeup \
         /sys/class/power_supply/qcom-battmgr-*/power/wakeup; do
    [ -w "$w" ] && echo disabled > "$w" 2>/dev/null && log "wakeup disabled: $w"
done

suspend_enabled=false
[ -e /etc/charging-mode/enable-suspend ] && suspend_enabled=true
log "suspend cycling: $suspend_enabled (flag /etc/charging-mode/enable-suspend)"

check_unplug() {
    # debounced: three reads ~3 s apart must all say offline
    n=0
    while [ "$(cat "$USB/online" 2>/dev/null || echo 1)" = "0" ]; do
        n=$((n + 1))
        if [ "$n" -ge 3 ]; then
            log "charger removed (capacity $(cat "$BAT/capacity" 2>/dev/null)%) - powering off"
            exec systemctl poweroff
        fi
        sleep 3
    done
}

sample() {
    log "sample: cap $(cat "$BAT/capacity" 2>/dev/null)% status $(cat "$BAT/status" 2>/dev/null) bat $(cat "$BAT/current_now" 2>/dev/null)uA cc $(cat "$BAT/charge_counter" 2>/dev/null)uAh usb $(cat "$USB/voltage_now" 2>/dev/null)uV $(cat "$USB/current_now" 2>/dev/null)uA icl $(cat "$USB/input_current_limit" 2>/dev/null)uA online $(cat "$USB/online" 2>/dev/null)"
}

suspending() {
    $suspend_enabled && [ ! -e /run/charging-mode-ssh ] && [ ! -e /run/charging-mode-display ]
}

tick=0
thrash=0
while :; do
    check_unplug
    # when suspend-cycling, log a full sample at EVERY wake — the persistent
    # journal is the offline logger for charger tests where no ssh path
    # exists (e.g. the PD brick occupying the USB port); in awake mode log
    # once a minute
    if suspending || [ $((tick % 12)) -eq 0 ]; then
        sample
    fi
    tick=$((tick + 1))

    if suspending && [ -w "$WAKEALARM" ]; then
        echo 0 > "$WAKEALARM" 2>/dev/null
        echo "+$SUSPEND_SECS" > "$WAKEALARM" 2>/dev/null
        if [ -n "$(cat "$WAKEALARM" 2>/dev/null)" ]; then
            t0=$(date +%s)
            echo mem > /sys/power/state 2>/dev/null || { log "suspend write failed - falling back to sleep"; sleep 30; }
            dur=$(( $(date +%s) - t0 ))
            log "slept ${dur}s"
            # thrash guard: instant resumes back-to-back nearly killed UFS
            # on the PD brick (2026-08-24) — three short cycles in a row
            # means something wakes us constantly; stop suspending and stay
            # in awake mode (still fine: any real charger out-supplies it)
            if [ "$dur" -lt 10 ]; then
                thrash=$((thrash + 1))
                if [ "$thrash" -ge 3 ]; then
                    log "suspend thrash (3 consecutive <10s cycles) - disabling suspend cycling this session"
                    suspend_enabled=false
                fi
            else
                thrash=0
            fi
        else
            log "could not arm RTC wakealarm - NOT suspending (sleep fallback)"
            sleep 30
        fi
    else
        sleep 5
    fi
done
