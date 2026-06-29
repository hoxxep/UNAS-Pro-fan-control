#!/bin/bash

# Sensor discovery for UNAS/UNVR devices.
#
# READ-ONLY: dumps every hwmon chip, thermal zone, and fan/PWM channel together
# with its kernel name and label. It does NOT change any fan speed. Use it to
# see exactly what each temperature sensor and fan is, so fan_control.sh can map
# them correctly across the device range (UNAS 2 ... EUNAS/ENVR).
#
# Run on the device:        /root/sensors.sh
# Or without installing:    ssh HOST 'bash -s' < sensors.sh
#
# Please paste the output into a GitHub issue when confirming a new device.
#
# Repo: https://github.com/hoxxep/UNAS-Pro-fan-control
# Author: Liam Gray
# License: MIT

set -uo pipefail

# Echo a sysfs file's contents, or "?" if it is missing/unreadable.
read_raw() {
    local v
    v="$(cat "$1" 2>/dev/null)" || { echo "?"; return; }
    [[ -n "$v" ]] && echo "$v" || echo "?"
}

# Echo a sysfs millidegree-Celsius file as whole degrees C, or "?" on failure.
read_milli_c() {
    local v
    v="$(cat "$1" 2>/dev/null)" || { echo "?"; return; }
    [[ "$v" =~ ^-?[0-9]+$ ]] || { echo "?"; return; }
    echo "$(( v / 1000 ))"
}

echo "=================================================================="
echo " hwmon chips        /sys/class/hwmon/*"
echo "   (temps, fan tachometers in RPM, and PWM outputs per chip)"
echo "=================================================================="
for h in /sys/class/hwmon/hwmon*; do
    [[ -e "$h" ]] || continue
    echo
    echo "$h   name=$(read_raw "$h/name")"

    # Temperature inputs with their labels.
    for t in "$h"/temp*_input; do
        [[ -e "$t" ]] || continue
        label="$(read_raw "${t%_input}_label")"
        [[ "$label" == "?" ]] && label="(no label)"
        printf "   %-12s %4s°C    label=%s\n" "$(basename "$t")" "$(read_milli_c "$t")" "$label"
    done

    # Fan tachometers (0 RPM usually means no fan on that header).
    for f in "$h"/fan*_input; do
        [[ -e "$f" ]] || continue
        label="$(read_raw "${f%_input}_label")"
        [[ "$label" == "?" ]] && label=""
        printf "   %-12s %5s RPM  %s\n" "$(basename "$f")" "$(read_raw "$f")" "$label"
    done

    # PWM outputs and their control mode (skip pwmN_enable/_mode siblings).
    # The enable flag matters for safety: a channel stuck on 1 (manual) is being
    # held at a fixed speed by fan_control.sh and will not respond to heat if the
    # service has stopped. Run `fan_control.sh --restore` to return them to 2.
    for p in "$h"/pwm*; do
        [[ -e "$p" ]] || continue
        bn="$(basename "$p")"
        [[ "$bn" =~ ^pwm[0-9]+$ ]] || continue
        en="$(read_raw "${p}_enable")"
        case "$en" in
            0)  mode="no SW control / full speed" ;;
            1)  mode="manual (fan_control sets this)" ;;
            \?) mode="" ;;
            *)  mode="automatic / chip curve" ;;
        esac
        printf "   %-12s val=%-4s enable=%-2s %s\n" "$bn" "$(read_raw "$p")" "$en" "$mode"
    done
done

echo
echo "=================================================================="
echo " thermal zones      /sys/class/thermal/*"
echo "   (SoC-internal sensors; 'type' identifies CPU/SoC/DDR/etc.)"
echo "=================================================================="
for z in /sys/class/thermal/thermal_zone*; do
    [[ -e "$z" ]] || continue
    printf "   %-24s %4s°C    type=%s\n" "$(basename "$z")" "$(read_milli_c "$z/temp")" "$(read_raw "$z/type")"
done

# Bonus: lm-sensors view if it happens to be installed (nicer labels).
if command -v sensors >/dev/null 2>&1; then
    echo
    echo "=================================================================="
    echo " lm-sensors         (sensors)"
    echo "=================================================================="
    sensors 2>/dev/null || true
fi

echo
echo "------------------------------------------------------------------"
echo "pwm enable legend:  0 = no software control (firmware/full speed)"
echo "                    1 = manual (fan_control.sh sets the value)"
echo "                    2+ = automatic / chip thermal curve"
echo "------------------------------------------------------------------"
