#!/usr/bin/env python3
"""Read (and optionally retune) UniFi OS's own fan controller (uhwd) on a UNAS Pro.

Instead of fighting uhwd by writing pwm* directly, this edits its PID setpoints
in the Status Database (config.fan) so uhwd itself keeps the box cooler:

  - CPU setpoint -> 70 C   (stock default 83)
  - HDD setpoint -> 38 C   (stock default 48)
  - HDD gains    -> Kp -2, Ki -0.02  (stock -1 / -0.01)
  - idle output  -> 15     (unchanged from stock)

Each per-category PID array is:
  [ setpoint_C, Kp, Ki, Kd, bool, target_group, MIN_FLOOR ]
The HDD gains are doubled because drives are slow, high-mass thermal loads: with
the stock gains the loop takes a long time to pull them back down to a setpoint
this much lower than stock.

Index 6 (MIN_FLOOR) is a per-category *minimum* fan output, NOT a max cap. The
PID floors at this value and ramps UP on its own as the temperature rises past
the setpoint -- so lowering the setpoint already cools harder on its own.
(The stock "cooling" preset just sets index 6 to 100, i.e. pins the fans full.)
Leave it at 15 for a quiet idle; raising it only makes idle louder.

The per-category floor and the global `standby` output are both "what the fans
do when there's no heat to shift", and stock sets them to the same value, so
--idle drives both rather than pointlessly exposing two knobs.

Run on the UNAS as root:

  python3 fan_control.py                      # read-only: current vs proposed
  python3 fan_control.py --write              # apply the change and restart uhwd
  python3 fan_control.py --hdd 40 --write     # apply custom setpoints
  python3 fan_control.py --restore --write    # put the stock values back

NOTE: config.fan is volatile -- uhwd re-initialises it to stock defaults on a
full reboot (a plain `systemctl restart uhwd` keeps these values). To make it
persist, re-run this at boot from a systemd unit ordered After=uhwd.service.
See install.sh, which sets that up for you.
"""

import argparse
import json
import subprocess
import sys
import threading
import time

from ustd.statusdb.sdb_client import SDBClient

# --- Defaults (override on the command line) ---------------------------------
CPU_SETPOINT = 70   # PID["cpu"][0], degrees C
HDD_SETPOINT = 40   # PID["hdd"][0], degrees C
IDLE = 15           # PID[*][6] and standby: fan output with no heat to shift
HDD_KP = -2         # PID["hdd"][1], stock -1
HDD_KI = -0.02      # PID["hdd"][2], stock -0.01
# -----------------------------------------------------------------------------

# Only used when the factory profile can't be read; see stock_values().
STOCK_CPU = 83
STOCK_HDD = 48
STOCK_IDLE = 15

# [ setpoint_C, Kp, Ki, Kd, bool, target_group, MIN_FLOOR ]
SETPOINT_IDX = 0
KP_IDX = 1
KI_IDX = 2
FLOOR_IDX = 6
PID_LEN = 7

# The keys uhwd derives from the active profile when you pick a preset in the
# UniFi UI. --restore copies them back from the (untouched) stored profile.
PROFILE_KEYS = ("PID", "targets", "standby", "calc_type")


def connect():
    c = SDBClient()
    threading.Thread(target=c.run, daemon=True).start()
    time.sleep(1)
    return c


def check_shape(pid):
    """Bail out unless every PID array is the length our fixed indices assume.

    We write by index, so a build of uhwd that adds, drops or reorders a field
    would have us setting the wrong ones -- refuse rather than guess. (--restore
    copies whole arrays around and never indexes, so it skips this check and
    still works on such a box.)
    """
    for name, values in pid.items():
        if isinstance(values, list) and len(values) == PID_LEN:
            continue
        found = (
            f"{len(values)} entries" if isinstance(values, list)
            else f"type {type(values).__name__}"
        )
        sys.exit(
            f"\nconfig.fan PID[{name!r}] has {found}, expected {PID_LEN} "
            "([setpoint_C, Kp, Ki, Kd, bool, target_group, MIN_FLOOR]). This "
            "build of uhwd lays its PID config out differently, so writing by "
            "index would hit the wrong fields. Nothing written -- please open "
            "a GitHub issue with the output above."
        )


def retune(fan, cpu, hdd, idle):
    """Set the CPU/HDD setpoints, the HDD gains, and the idle fan output, in place."""
    pid = fan["PID"]
    check_shape(pid)
    if "cpu" in pid:
        pid["cpu"][SETPOINT_IDX] = cpu
        pid["cpu"][FLOOR_IDX] = idle
    if "hdd" in pid:
        pid["hdd"][SETPOINT_IDX] = hdd
        pid["hdd"][KP_IDX] = HDD_KP
        pid["hdd"][KI_IDX] = HDD_KI
        pid["hdd"][FLOOR_IDX] = idle
    fan["standby"] = idle


def restore(fan):
    """Copy the active factory profile back over the live config, in place.

    We never write into fan["profiles"], so the stock Quiet/Default/Cooling
    presets are still pristine and one of them is always the truth about what
    this box shipped with. Returns the profile name used.
    """
    profiles = fan.get("profiles") or {}
    name = fan.get("active_profile") or "default"
    profile = profiles.get(name) or profiles.get("default")
    if not profile:
        sys.exit(
            "No stored profile to restore from (config.fan has no usable "
            "'profiles' entry). Reboot, or switch the fan preset in the UniFi "
            "UI, to get the stock values back."
        )
    for key in PROFILE_KEYS:
        if key in profile:
            fan[key] = json.loads(json.dumps(profile[key]))  # deep copy
    return name if name in profiles else "default"


def stock_values(fan):
    """This box's factory (cpu, hdd, idle), for showing next to our defaults.

    Read from fan["profiles"], which we never write to, so it stays the truth
    about what the box shipped with even after a retune -- and it follows the
    preset picked in the UniFi UI, e.g. "cooling" really does idle at 100.
    Falls back to the STOCK_* constants for anything missing, since this only
    feeds a display: the real config is validated when we come to write it.
    """
    fan = fan or {}
    profiles = fan.get("profiles") or {}
    profile = profiles.get(fan.get("active_profile")) or profiles.get("default") or {}
    pid = profile.get("PID") or {}

    def value(name, index, fallback):
        values = pid.get(name)
        if isinstance(values, list) and len(values) > index:
            if isinstance(values[index], (int, float)) and not isinstance(values[index], bool):
                return values[index]
        return fallback

    return (
        value("cpu", SETPOINT_IDX, STOCK_CPU),
        value("hdd", SETPOINT_IDX, STOCK_HDD),
        value("hdd", FLOOR_IDX, profile.get("standby", STOCK_IDLE)),
    )


def show(label, fan):
    print(f"{label}:", json.dumps(fan.get("PID"), indent=2), "standby=", fan.get("standby"))


def temperature(low, high):
    def parse(value):
        try:
            number = int(value)
        except ValueError:
            raise argparse.ArgumentTypeError(f"{value!r} is not an integer")
        if not low <= number <= high:
            raise argparse.ArgumentTypeError(f"{number} is outside {low}-{high}")
        return number

    return parse


def main():
    parser = argparse.ArgumentParser(
        description="Show uhwd's live fan PID config; pass --write to retune it."
    )
    parser.add_argument(
        "--write",
        action="store_true",
        help="write to config.fan and restart uhwd (default is read-only)",
    )
    parser.add_argument(
        "--cpu",
        type=temperature(40, 95),
        default=CPU_SETPOINT,
        metavar="C",
        help=f"CPU setpoint in degrees C (default {CPU_SETPOINT}, stock {STOCK_CPU})",
    )
    parser.add_argument(
        "--hdd",
        type=temperature(25, 60),
        default=HDD_SETPOINT,
        metavar="C",
        help=f"HDD setpoint in degrees C (default {HDD_SETPOINT}, stock {STOCK_HDD})",
    )
    parser.add_argument(
        "--idle",
        type=temperature(0, 100),
        default=IDLE,
        metavar="N",
        help=f"fan output when idle: the per-category PID floor and the global "
             f"standby output, which stock keeps equal (default {IDLE}). This is "
             f"a minimum, not a cap; raising it only makes idle louder",
    )
    parser.add_argument(
        "--restore",
        action="store_true",
        help="restore the stock values from the active factory profile instead "
             "of retuning",
    )
    parser.add_argument(
        "--defaults",
        action="store_true",
        help="print the built-in defaults as 'cpu hdd idle' and exit; lets "
             "install.sh show them without keeping its own copy",
    )
    parser.add_argument(
        "--stock",
        action="store_true",
        help="print this box's factory values as 'cpu hdd idle' and exit, read "
             "from the active preset's stored profile",
    )
    args = parser.parse_args()

    if args.defaults:
        print(CPU_SETPOINT, HDD_SETPOINT, IDLE)
        return

    if args.stock:
        try:
            fan = connect().get("config.fan")
        except Exception:  # uhwd down, no SDB -- fall back to the constants
            fan = None
        # Whole numbers come back as floats; print them as the ints they are.
        print(*(int(v) if float(v).is_integer() else v for v in stock_values(fan)))
        return

    c = connect()
    fan = c.get("config.fan")
    if not fan or "PID" not in fan:
        sys.exit("config.fan not found or unexpected shape; is uhwd running?")

    show("Current ", fan)

    if args.restore:
        name = restore(fan)
        print(f"\nRestoring from the {name!r} factory profile.")
    else:
        # Edit ONLY the live/top-level config. We deliberately do NOT write into
        # fan["profiles"][...]: those are the factory Quiet/Balanced/Cooling
        # presets, and overwriting one destroys your ability to return to it --
        # including via --restore above. If uhwd re-derives the live config from
        # the active profile (e.g. when you switch presets in the UI), these
        # values revert; persist them by re-running at boot instead.
        retune(fan, args.cpu, args.hdd, args.idle)

    show("New     " if args.write else "Proposed", fan)

    if not args.write:
        print("\nRead-only: nothing written. Re-run with --write to apply.")
        return

    c.update("config.fan", fan)
    print("\nconfig.fan updated. Restarting uhwd to apply...")
    subprocess.run(["systemctl", "restart", "uhwd"], check=False)
    print("Done. Watch temps/fan RPM with: bash sensors.sh")


if __name__ == "__main__":
    main()
