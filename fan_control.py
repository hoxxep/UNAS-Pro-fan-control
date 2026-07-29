#!/usr/bin/env python3
"""Read (and optionally retune) UniFi OS's own fan controller (uhwd) on a UNAS Pro.

Instead of fighting uhwd by writing pwm* directly, this edits its PID setpoints
in the Status Database (config.fan) so uhwd itself keeps the box cooler:

  - CPU setpoint -> 70 C   (stock default 83)
  - HDD setpoint -> 40 C   (stock default 48)
  - NVMe setpoint-> 60 C   (stock default 60, on boxes with NVMe drives)
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
Leave it at 15 for a quiet idle; raising it only makes idle louder. It is set on
every category, since they share the fans and one left at 100 pins them at full.

The per-category floor and the global `standby` output are both "what the fans
do when there's no heat to shift", and stock sets them to the same value, so
--idle drives both rather than pointlessly exposing two knobs.

Run on the UNAS as root:

  python3 fan_control.py                      # read-only: current vs proposed
  python3 fan_control.py --write              # apply the change and restart uhwd
  python3 fan_control.py --hdd 40 --write     # apply custom setpoints
  python3 fan_control.py --restore --write    # put the factory values back

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
NVME_SETPOINT = 60  # PID["nvme"][0], degrees C. Stock: these drives idle in the
                    # low 50s, so lowering it only adds fan noise.
IDLE = 15           # PID[*][6] and standby: fan output with no heat to shift
HDD_KP = -2         # PID["hdd"][1], stock -1
HDD_KI = -0.02      # PID["hdd"][2], stock -0.01
# -----------------------------------------------------------------------------

# Only used when the live config can't be read; see current_values().
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


def retune(fan, cpu, hdd, nvme, idle):
    """Set the setpoints, the HDD gains, and the idle fan output, in place."""
    pid = fan["PID"]
    check_shape(pid)
    setpoints = {"cpu": cpu, "hdd": hdd, "nvme": nvme}
    for name, values in pid.items():
        if name in setpoints:
            values[SETPOINT_IDX] = setpoints[name]
        # Every category, not just the ones we set a setpoint for: they share
        # the fans, so one left at 100 (as the "cooling" preset sets them all)
        # pins the fans at full.
        values[FLOOR_IDX] = idle
    if "hdd" in pid:
        pid["hdd"][KP_IDX] = HDD_KP
        pid["hdd"][KI_IDX] = HDD_KI
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


def current_values(fan):
    """What the fans are being run to now: (cpu, hdd, idle, nvme).

    Read from the live top-level config, so on a re-run this reports what the
    last install set rather than what the box shipped with. Falls back to the
    STOCK_* constants for anything missing, since this only feeds a display:
    the real config is validated when we come to write it. `nvme` is None on
    the models that have no such category.
    """
    fan = fan or {}
    pid = fan.get("PID") or {}

    def value(name, index, fallback=None):
        values = pid.get(name)
        if isinstance(values, list) and len(values) > index:
            if isinstance(values[index], (int, float)) and not isinstance(values[index], bool):
                return values[index]
        return fallback

    return (
        value("cpu", SETPOINT_IDX, STOCK_CPU),
        value("hdd", SETPOINT_IDX, STOCK_HDD),
        value("hdd", FLOOR_IDX, fan.get("standby", STOCK_IDLE)),
        value("nvme", SETPOINT_IDX),
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
        "--nvme",
        type=temperature(35, 75),
        default=NVME_SETPOINT,
        metavar="C",
        help=f"NVMe setpoint in degrees C, on the models that have one "
             f"(default {NVME_SETPOINT}, i.e. stock)",
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
        help="print the built-in defaults as 'cpu hdd idle nvme' and exit; lets "
             "install.sh show them without keeping its own copy",
    )
    parser.add_argument(
        "--current",
        action="store_true",
        help="print this box's live values as 'cpu hdd idle nvme' and exit, with "
             "nvme omitted on boxes that have no NVMe category",
    )
    args = parser.parse_args()

    if args.defaults:
        print(CPU_SETPOINT, HDD_SETPOINT, IDLE, NVME_SETPOINT)
        return

    if args.current:
        try:
            fan = connect().get("config.fan")
        except Exception:  # uhwd down, no SDB -- fall back to the constants
            fan = None
        # nvme is last so it can simply be absent, leaving a shell caller's
        # `read -r cpu hdd idle nvme` with an empty nvme. Whole numbers come
        # back as floats; print them as the ints they are.
        values = [v for v in current_values(fan) if v is not None]
        print(*(int(v) if float(v).is_integer() else v for v in values))
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
        retune(fan, args.cpu, args.hdd, args.nvme, args.idle)

    show("New     " if args.write else "Proposed", fan)

    if not args.write:
        print("\nRead-only: nothing written. Re-run with --write to apply.")
        return

    c.update("config.fan", fan)
    print("\nconfig.fan updated. Restarting uhwd to apply...")
    subprocess.run(["systemctl", "restart", "uhwd"], check=False)
    print("Done. Watch temps/fan RPM with: bash fan_sensors.sh")


if __name__ == "__main__":
    main()
