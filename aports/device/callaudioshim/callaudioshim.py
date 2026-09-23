#!/usr/bin/env python3
"""callaudioshim.py — drop-in replacement for callaudiod on the FP6.

Stock callaudiod 0.1.99 is broken on this hardware: it never finds a
"voice-capable" PulseAudio card (our UCM exposes HiFi with Speaker+Mic, no
Earpiece port), so
  - its MicState property stays at the D-Bus default 0 = MIC_OFF and
    plasma-dialer's in-call page permanently shows the mic as MUTED;
  - MuteMic() bails with "card has no usable source" — the mute button does
    nothing;
  - SelectMode() never replies, blocking kde-telephony-daemon's main loop for
    the full 25 s GDBus timeout on every call (journal/ims.md s41).

A second, independent upstream defect (plasma-dialer 6.7.3) makes the UI state
wrong even with a working callaudiod: the mute button binds to
kde-telephony-daemon's DialerUtils `m_mute` — an UNINITIALIZED bool that
nothing ever syncs with reality (it only changes on button presses, and the
daemon never re-reads MicState). So every call page opened showing "muted"
while the mic was live, and the first press was wasted re-syncing. This shim
papers over that too: whenever the REAL mic state changes (and whenever
kde-telephony-daemon [re]appears on the bus), it pushes the truth into
DialerUtils.setMute(b), which updates m_mute and fires muteChanged to the UI.
The loop is self-terminating (the daemon only re-emits on value change, and
the bounce-back MuteMic is a no-op when the state already matches).

This shim owns org.mobian_project.CallAudio instead and implements the same
interface (verified against callaudiod's org.mobian_project.CallAudio.xml):
  - MuteMic(b) mutes/unmutes @DEFAULT_AUDIO_SOURCE@ via wpctl. The default
    source is ec_source (the AEC'd mic, s43), which every capture stream —
    including the call's pw-record — consumes, so mute = real uplink silence
    (verified: tone capture RMS 94.5 -> 0.0 on mute).
  - MicState mirrors the ACTUAL source mute (polled every 2 s too, so
    out-of-band wpctl/pactl changes stay reflected), with PropertiesChanged
    so kde-telephony-daemon's cached GDBusProxy tracks it.
  - SelectMode / EnableSpeaker reply immediately (bookkeeping only: the
    loudspeaker is the only output today, and UCM verb switching is not
    dynamic in this setup — journal/audio.md 2026-07-18). SpeakerState
    defaults to ON. When an Earpiece UCM device exists these become real.

Stock callaudiod must not own the name. The package replaces callaudiod's
D-Bus activation file with one that starts this shim, so whichever client asks
first — Phosh activates the name at startup, before autostart runs — gets the
shim; the KDE early-phase autostart stays for the DialerUtils push at session
start. Runs as the session user, no root needed.
"""
import subprocess

import dbus
import dbus.service
import dbus.mainloop.glib
from gi.repository import GLib

BUS_NAME = "org.mobian_project.CallAudio"
OBJ_PATH = "/org/mobian_project/CallAudio"
IFACE = "org.mobian_project.CallAudio"
PROPS_IFACE = "org.freedesktop.DBus.Properties"
SOURCE = "@DEFAULT_AUDIO_SOURCE@"

# kde-telephony-daemon's DialerUtils — the mute-button state lives there
DIALER_BUS = "org.kde.telephony.DialerUtils"
DIALER_PATH = "/org/kde/telephony/DialerUtils/tel/mm"
DIALER_IFACE = "org.kde.telephony.DialerUtils"

MODE_DEFAULT, MODE_CALL = 0, 1
OFF, ON, UNKNOWN = 0, 1, 255


def log(msg):
    print(msg, flush=True)


def source_muted():
    """True/False from wpctl ('Volume: 1.00 [MUTED]'), None if unreadable."""
    try:
        out = subprocess.run(["wpctl", "get-volume", SOURCE],
                             capture_output=True, text=True, timeout=5).stdout
    except (OSError, subprocess.TimeoutExpired):
        return None
    if "Volume:" not in out:
        return None
    return "[MUTED]" in out


def set_source_muted(mute):
    return subprocess.run(
        ["wpctl", "set-mute", SOURCE, "1" if mute else "0"],
        capture_output=True, timeout=5).returncode == 0


class CallAudio(dbus.service.Object):
    def __init__(self, bus):
        super().__init__(bus, OBJ_PATH)
        self.bus = bus
        self.audio_mode = MODE_DEFAULT
        self.speaker_state = ON      # loudspeaker is the only output today
        m = source_muted()
        self.mic_state = UNKNOWN if m is None else (OFF if m else ON)
        log(f"callaudioshim: up, MicState={self.mic_state}")
        GLib.timeout_add_seconds(2, self._poll)
        self._push_dialer()
        # re-push whenever kde-telephony-daemon (re)appears: its m_mute is an
        # uninitialized bool until someone calls setMute
        bus.watch_name_owner(DIALER_BUS, self._dialer_owner_changed)

    # -------------------------------------------- DialerUtils state push
    def _dialer_owner_changed(self, owner):
        if owner:
            log(f"callaudioshim: DialerUtils owner {owner}; pushing mute state")
            self._push_dialer()

    def _push_dialer(self):
        if self.mic_state == UNKNOWN:
            return
        try:
            self.bus.call_async(DIALER_BUS, DIALER_PATH, DIALER_IFACE,
                                "setMute", "b", (self.mic_state == OFF,),
                                lambda *a: None, lambda *a: None)
        except dbus.DBusException:
            pass

    # ------------------------------------------------ property plumbing
    def _props(self):
        return {
            "AudioMode": dbus.UInt32(self.audio_mode),
            "SpeakerState": dbus.UInt32(self.speaker_state),
            "MicState": dbus.UInt32(self.mic_state),
        }

    def _set(self, attr, prop, value):
        if getattr(self, attr) == value:
            return
        setattr(self, attr, value)
        self.PropertiesChanged(IFACE, {prop: dbus.UInt32(value)}, [])
        if prop == "MicState":
            self._push_dialer()

    def _poll(self):
        # catch out-of-band mute changes (wpctl, pactl, other clients)
        m = source_muted()
        if m is not None:
            self._set("mic_state", "MicState", OFF if m else ON)
        return True

    @dbus.service.method(PROPS_IFACE, in_signature="ss", out_signature="v")
    def Get(self, interface, prop):
        return self._props()[prop]

    @dbus.service.method(PROPS_IFACE, in_signature="s", out_signature="a{sv}")
    def GetAll(self, interface):
        return self._props()

    @dbus.service.signal(PROPS_IFACE, signature="sa{sv}as")
    def PropertiesChanged(self, interface, changed, invalidated):
        pass

    # ------------------------------------------------ org.mobian_project.CallAudio
    @dbus.service.method(IFACE, in_signature="u", out_signature="b")
    def SelectMode(self, mode):
        if mode not in (MODE_DEFAULT, MODE_CALL):
            raise dbus.exceptions.DBusException(
                "invalid mode", name="org.freedesktop.DBus.Error.InvalidArgs")
        log(f"callaudioshim: SelectMode({int(mode)})")
        self._set("audio_mode", "AudioMode", int(mode))
        if mode == MODE_DEFAULT:
            # leaving a call: never leave the mic muted behind
            if source_muted():
                set_source_muted(False)
                self._set("mic_state", "MicState", ON)
        return True

    @dbus.service.method(IFACE, in_signature="b", out_signature="b")
    def EnableSpeaker(self, enable):
        log(f"callaudioshim: EnableSpeaker({bool(enable)})")
        self._set("speaker_state", "SpeakerState", ON if enable else OFF)
        return True

    @dbus.service.method(IFACE, in_signature="b", out_signature="b")
    def MuteMic(self, mute):
        ok = set_source_muted(bool(mute))
        log(f"callaudioshim: MuteMic({bool(mute)}) -> {ok}")
        if not ok:
            return False
        self._set("mic_state", "MicState", OFF if mute else ON)
        return True


def main():
    dbus.mainloop.glib.DBusGMainLoop(set_as_default=True)
    session = dbus.SessionBus()
    try:
        name = dbus.service.BusName(BUS_NAME, session, do_not_queue=True)  # noqa: F841
    except dbus.exceptions.NameExistsException:
        # activated and autostarted in the same session: the first one serves
        log(f"callaudioshim: {BUS_NAME} already owned; exiting")
        return
    CallAudio(session)
    log(f"callaudioshim: owning {BUS_NAME}")
    GLib.MainLoop().run()


if __name__ == "__main__":
    main()
