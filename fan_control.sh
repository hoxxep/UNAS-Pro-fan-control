#!/bin/bash

# Fan control service for a UNAS Pro.
#
# Run directly as /root/fan_control.sh to query current temps and computed fan
# speeds, and write those speeds once so you can experiment by hand. A manual run
# leaves the fan mode (pwm*_enable) untouched, so the chip stays free to resume
# its own automatic curve and a one-off run can never leave the fans pinned.
# Only --service also takes over manual control (pwm*_enable=1) so the chosen
# speed sticks against the chip's automatic algorithm.
# Use the --service flag to loop once per minute and prevent logging to stdout.
# Use the --restore flag to hand the fans back to automatic control (undo manual
# mode) before stopping or uninstalling, so fans are never left pinned in place.
#
# Repo: https://github.com/hoxxep/UNAS-Pro-fan-control
# Author: Liam Gray
# License: MIT

set -euo pipefail

# TGT = desired healthy temp in Celcius to run at 15% fans
# MAX = unhealthy temp to run at 100% fans
# Fan speed will be set linearly based on the current temp between TGT and MAX.
# See README.md for tips on configuring these arguments.
# The "system" curve covers the CPU die (thermal zones) and the board/airflow
# sensors on the fan-controller chip (e.g. adt7475). The hottest of these drives
# it. See get_system_temps() for how these sensors are discovered.
SYS_TGT=50
# SYS_MAX 85: the SoC throttles ~85°C+, and the hottest board diode (adt7475
# temp3) runs ~12°C above the CPU die at idle. A wider TGT..MAX span also
# flattens the curve slope so small temp wobbles don't slam the fans around.
SYS_MAX=85
HDD_TGT=32
HDD_MAX=55
# SSDs (SATA and NVMe) tolerate higher temperatures than spinning disks.
# Tuned for NVMe drives, which often have little airflow; safe for SATA SSDs too.
SSD_TGT=50
SSD_MAX=70
MIN_FAN=39  # 15% of 255 (increase baseline to reduce fan speed variation)
MAX_FAN=255 # Fan speed ceiling (reduce to cap noise; caps the curve even when overheating)

# Optional MQTT-bridge hooks (fan_control_state.sh): apply_fan_conf applies
# validated fan-curve overrides tuned from Home Assistant, and the state_*
# hooks snapshot readings for the bridge. The no-op stubs below are the
# defaults; a missing or broken helper leaves them in place, so fan control
# never depends on the helper or the MQTT bridge.
apply_fan_conf() { :; }
state_begin() { :; }
state_add_drive() { :; }
state_end() { :; }
if [[ -f /root/fan_control_state.sh ]]; then
    source /root/fan_control_state.sh 2>/dev/null || true
fi

usage() {
    cat <<'EOF'
Usage: fan_control.sh [--service | --restore | -h | --help]

Temperature-driven fan control for a UNAS Pro (and similar) chassis. With no
argument it logs the current temperatures and computed fan speeds and writes
those speeds once, leaving the fan mode (pwm*_enable) untouched so the chip can
resume its own automatic curve.

Options:
  (none)      One-shot: log temps/speeds and write the computed speed once,
              without taking over the fan mode. Handy for experimenting by hand.
  --service   Run as a daemon: take over manual control (pwm*_enable=1) and set
              the fan speed once every 60s, with no logging to stdout.
  --restore   Hand the fans back to the chip's automatic control and exit.
  -h, --help  Show this help and exit.

See README.md for tuning the temperature and fan-curve thresholds.
EOF
}

# SERVICE=true: loop once every 60s to set fan speed and temp, no LOGGING
# SERVICE=false: run once, logging temps and fan speed to console
# RESTORE=true: hand the fans back to automatic control and exit (see --restore)
LOGGING=true
SERVICE=false
RESTORE=false
case "${1:-}" in
    "")        ;;  # no argument: default one-shot manual run
    --service) LOGGING=false; SERVICE=true ;;
    --restore) RESTORE=true ;;
    -h|--help) usage; exit 0 ;;
    *)         echo "Unknown argument: $1" >&2; echo >&2; usage >&2; exit 2 ;;
esac

log_echo() {
    if $LOGGING; then
        echo "$@"
    fi
}

# Discover all SMART devices via a single scan and print one
# "<class>\t<device>\t<temperature_celsius>" line per device that reports a
# temperature, where <class> is HDD or SSD.
#
# The current temperature is read from the smartctl JSON using known fields in
# priority order:
#   1. temperature.current                              (ATA/SCSI/NVMe top-level)
#   2. nvme_smart_health_information_log.temperature    (NVMe fallback)
#   3. ATA SMART attribute 194/190, or a named temp attr (ATA fallback)
#
# Add --nocheck=standby to SMART_ARGS if you do not want to wake sleeping HDDs.
get_disk_temps() {
    local SMART_ARGS=(--json=c --all)
    local scan dev dtype json args

    scan="$(smartctl --json=c --scan-open 2>/dev/null || true)"

    while IFS=$'\t' read -r dev dtype; do
        [[ -n "$dev" ]] || continue

        args=("${SMART_ARGS[@]}")
        [[ -n "$dtype" ]] && args+=(-d "$dtype")

        json="$(smartctl "${args[@]}" "$dev" 2>/dev/null || true)"
        [[ -n "$json" ]] || continue

        jq -r --arg dev "$dev" '
            def trunc_c:
              if type == "number" then
                tostring | match("^-?[0-9]+").string | tonumber
              elif type == "string" then
                capture("^\\s*(?<n>-?[0-9]+)(?:\\.[0-9]+)?(?:\\s|$|[C(/])").n | tonumber
              else
                empty
              end;

            def sane:
              select(. >= -40 and . <= 150);

            def current_from_top:
              .temperature.current? | trunc_c | sane;

            def current_from_nvme_fallback:
              .nvme_smart_health_information_log.temperature? | trunc_c | sane;

            def current_from_ata_attr_fallback:
              [
                (.ata_smart_attributes.table // [])[]
                | select(
                    (.id == 194) or
                    (.id == 190 and ((.name // "") | test("(?i)(temperature|temp|airflow)"))) or
                    ((.name // "") | test("(?i)^(Temperature_Celsius|Airflow_Temperature_Cel|Drive_Temperature|Current_Temperature)$"))
                  )
                | {
                    priority: (
                      if .id == 194 then 0
                      elif .id == 190 then 1
                      else 2
                      end
                    ),
                    value: (
                      try ((.raw.string // .raw.value) | trunc_c | sane)
                      catch empty
                    )
                  }
                | select(.value != null)
              ]
              | sort_by(.priority)
              | .[0].value?;

            def device_class:
              if (.device.type? == "nvme") or (.nvme_smart_health_information_log? != null) then "SSD"
              elif (.rotation_rate? == 0) then "SSD"
              else "HDD"
              end;

            ([current_from_top, current_from_nvme_fallback, current_from_ata_attr_fallback] | first(.[]?)) as $temp
            | select($temp != null)
            | [(device_class), $dev, ($temp | tostring), (.serial_number // "")] | @tsv
        ' <<< "$json" 2>/dev/null || true
    done < <(jq -r '.devices[]? | [.name, (.type // "")] | @tsv' <<< "$scan" 2>/dev/null)
}

# Discover all "system" temperature sensors (CPU die + board/airflow) and print
# one "<source>\t<temperature_celsius>" line per sensor. Drives are handled
# separately by get_disk_temps(); drive (nvme/drivetemp) and PSU/PMBus monitor
# chips are skipped so a hot drive or PSU is not double-counted here.
#
# Sources, in order:
#   1. /sys/class/thermal/thermal_zone*       SoC zones (cpu-thermal, soc, ...)
#   2. /sys/class/hwmon/hwmon*/temp*_input    board / fan-controller chips
get_system_temps() {
    local zone ztype milli temp hw name t

    # SoC thermal zones: this is where the true CPU die temperature lives.
    for zone in /sys/class/thermal/thermal_zone*; do
        [[ -e "$zone/temp" ]] || continue
        milli="$(cat "$zone/temp" 2>/dev/null || true)"
        [[ "$milli" =~ ^-?[0-9]+$ ]] || continue
        temp=$(( milli / 1000 ))
        (( temp >= -40 && temp <= 150 )) || continue
        ztype="$(cat "$zone/type" 2>/dev/null || echo zone)"
        printf '%s\t%s\n' "${zone}/temp (${ztype})" "$temp"
    done

    # hwmon board / fan-controller chips (skip drive and PSU/PMBus chips).
    for hw in /sys/class/hwmon/hwmon*; do
        [[ -e "$hw" ]] || continue
        name="$(cat "$hw/name" 2>/dev/null || echo hwmon)"
        case "$name" in
            nvme|drivetemp) continue ;;            # drives, counted via SMART
            *pmbus*|*dps[0-9]*|*psu*) continue ;;  # PSU/BMC-managed monitors
        esac
        for t in "$hw"/temp*_input; do
            [[ -e "$t" ]] || continue
            milli="$(cat "$t" 2>/dev/null || true)"
            [[ "$milli" =~ ^-?[0-9]+$ ]] || continue
            temp=$(( milli / 1000 ))
            (( temp >= -40 && temp <= 150 )) || continue
            printf '%s\t%s\n' "${t} (${name})" "$temp"
        done
    done
}

set_fan_speed() {
    # Apply Home Assistant/MQTT parameter overrides, and reset the state
    # snapshot for this iteration (no-ops unless the MQTT bridge is set up).
    apply_fan_conf
    state_begin

    # Auto-discover all system temperature sensors (CPU die + board/airflow) and
    # track the hottest. See get_system_temps().
    SYS_TEMP=0
    while IFS=$'\t' read -r src temp; do
        [[ "$temp" =~ ^-?[0-9]+$ ]] || continue
        log_echo "${src} System Temperature: ${temp}°C"
        if [ "$temp" -gt "$SYS_TEMP" ]; then SYS_TEMP=$temp; fi
    done < <(get_system_temps)

    # Initialize maximum HDD/SSD temperatures
    HDD_TEMP=0
    SSD_TEMP=0

    # Auto-discover all SMART devices and read each one's temperature, tracking
    # the hottest HDD and the hottest SSD separately. See get_disk_temps().
    while IFS=$'\t' read -r class dev temp serial; do
        [[ "$temp" =~ ^-?[0-9]+$ ]] || continue
        log_echo "${dev} ${class} Temperature: ${temp}°C"
        state_add_drive "$class" "$dev" "$temp" "$serial"
        if [[ "$class" == "SSD" ]]; then
            if [ "$temp" -gt "$SSD_TEMP" ]; then SSD_TEMP=$temp; fi
        else
            if [ "$temp" -gt "$HDD_TEMP" ]; then HDD_TEMP=$temp; fi
        fi
    done < <(get_disk_temps)

    # Function to calculate fan curve. The speed ramps linearly from MIN_FAN at
    # the target temp (tgt) to MAX_FAN (default 255 = 100%) at the max temp,
    # and is held at MIN_FAN below tgt. Scaling into [MIN_FAN, MAX_FAN] means
    # the fan starts responding right at tgt, rather than ignoring rising temps
    # until a plain 0-based ramp happens to climb past the MIN_FAN floor.
    fan_curve() {
        local tgt=$1
        local actual=$2
        local max=$3

        fan_speed=$(awk -v tgt="$tgt" -v actual="$actual" -v max="$max" -v floor="$MIN_FAN" -v ceil="$MAX_FAN" '
        BEGIN {
            # Clamp the floor into the valid PWM range first. An absurdly
            # large floor (bad MIN_FAN edit) otherwise cancels catastrophically
            # in floor + ratio * (ceil - floor) and prints 0 -- commanding the
            # fans OFF precisely when overheating.
            if (floor < 0) floor = 0
            if (floor > 255) floor = 255
            # Invalid ceiling (below the floor or above 255, e.g. bad MAX_FAN
            # edit): fail hot with the full range rather than pinning the fans
            # below the floor.
            if (ceil < floor || ceil > 255) ceil = 255
            if (max <= tgt) {
                # Degenerate/inverted parameters (TGT >= MAX): fail hot.
                # Without this, actual <= tgt would swallow the whole range
                # and silently pin the fans at the minimum while overheating.
                ratio = (actual > tgt) ? 1 : 0
            } else if (actual <= tgt) {
                ratio = 0
            } else if (actual >= max) {
                ratio = 1
            } else {
                ratio = (actual - tgt) / (max - tgt)
            }
            if (ratio < 0) ratio = 0
            if (ratio > 1) ratio = 1
            printf "%d", floor + ratio * (ceil - floor)
        }')
        echo "$fan_speed"
    }

    # Calculate fan speeds
    HDD_FAN=$(fan_curve "$HDD_TGT" "$HDD_TEMP" "$HDD_MAX")
    SSD_FAN=$(fan_curve "$SSD_TGT" "$SSD_TEMP" "$SSD_MAX")
    SYS_FAN=$(fan_curve "$SYS_TGT" "$SYS_TEMP" "$SYS_MAX")

    # Take the maximum of the HDD, SSD, and system fan speeds
    FAN_SPEED=$(( HDD_FAN > SYS_FAN ? HDD_FAN : SYS_FAN ))
    FAN_SPEED=$(( SSD_FAN > FAN_SPEED ? SSD_FAN : FAN_SPEED ))
    FAN_SPEED=$(( MIN_FAN > FAN_SPEED ? MIN_FAN : FAN_SPEED ))

    # Output the values
    log_echo "Max HDD Temperature: ${HDD_TEMP}°C"
    log_echo "Max SSD Temperature: ${SSD_TEMP}°C"
    log_echo "Max System Temperature: ${SYS_TEMP}°C"

    log_echo "Min Fan Speed: ${MIN_FAN}"
    log_echo "Max Fan Speed: ${MAX_FAN}"
    log_echo "HDD Fan Speed: ${HDD_FAN}"
    log_echo "SSD Fan Speed: ${SSD_FAN}"
    log_echo "System Fan Speed: ${SYS_FAN}"
    log_echo "Final Fan Speed (Max): ${FAN_SPEED}"

    # Auto-discover fan-controller chips and drive every PWM channel on them. A
    # fan controller is an hwmon chip exposing both pwm* outputs and fan*_input
    # tachometers (e.g. adt7475). Drive chips (nvme/drivetemp) and PSU/PMBus
    # chips are skipped so we never hijack a PSU/BMC-managed fan. Note that PWM
    # channels and tachometers are not 1:1 (a chip may expose more PWMs than
    # connected fans), so every PWM is driven; tachometers are only logged.
    FAN_FOUND=0
    for hw in /sys/class/hwmon/hwmon*; do
        [[ -e "$hw" ]] || continue
        name="$(cat "$hw/name" 2>/dev/null || echo hwmon)"
        case "$name" in
            nvme|drivetemp) continue ;;
            *pmbus*|*dps[0-9]*|*psu*) continue ;;
        esac

        # Collect this chip's bare PWM outputs (pwm1, pwm2, ... not pwm1_enable).
        pwms=()
        for p in "$hw"/pwm*; do
            [[ -e "$p" ]] || continue
            [[ "$(basename "$p")" =~ ^pwm[0-9]+$ ]] && pwms+=("$p")
        done
        [[ ${#pwms[@]} -gt 0 ]] || continue

        # Require a tachometer too, so we only drive real fan controllers.
        has_tach=0
        for f in "$hw"/fan*_input; do
            [[ -e "$f" ]] && { has_tach=1; break; }
        done
        [[ "$has_tach" -eq 1 ]] || continue

        # Write the speed to each PWM. Only --service first switches the chip to
        # manual control (pwm*_enable=1) so the speed sticks; a plain manual run
        # writes the speed too (handy for experimenting) but leaves the mode
        # alone, so the chip can resume its own curve and never gets left pinned.
        for p in "${pwms[@]}"; do
            FAN_FOUND=1
            if $SERVICE; then
                [[ -w "${p}_enable" ]] && echo 1 > "${p}_enable" 2>/dev/null || true
            fi
            echo "$FAN_SPEED" > "$p" 2>/dev/null || true
            if $LOGGING; then
                set_to="$(cat "$p" 2>/dev/null || echo '?')"
                echo "Fan ${p} (${name}) set to ${FAN_SPEED}/255, reading ${set_to}/255."
            fi
        done

        # Log tachometers so it is visible whether the fans are actually spinning.
        if $LOGGING; then
            for f in "$hw"/fan*_input; do
                [[ -e "$f" ]] || continue
                echo "Tach $(basename "$f") (${name}): $(cat "$f" 2>/dev/null || echo '?') RPM"
            done
        fi
    done

    # If no fan controller found, log a clear error and exit.
    if (( FAN_FOUND == 0 )); then
        echo "No fan controller found (hwmon chip with pwm* outputs and fan*_input tachometers)."
        exit 1
    fi

    # Write the state snapshot for the MQTT bridge (no-op unless installed).
    state_end
}

# Hand the fans back to automatic (firmware/chip) control on every fan-controller
# chip we would otherwise drive. set_fan_speed() pins each PWM to manual mode
# (pwm*_enable=1) at a fixed speed; if this script then stops, crashes, or is
# uninstalled, the fans would stay at that fixed speed and no longer respond to
# heat. restore_auto() reverses that: it is run by `--restore` and by the
# systemd ExecStopPost hook, so stopping the service is always thermally safe.
#
# pwm*_enable=2 = the chip's own automatic temperature curve (quiet and safe). If
# a chip rejects 2, we fall back to 0 (= no software control / full speed), which
# is loud but can never leave the fans pinned too low.
restore_auto() {
    local hw name p bn mode found=0
    for hw in /sys/class/hwmon/hwmon*; do
        [[ -e "$hw" ]] || continue
        name="$(cat "$hw/name" 2>/dev/null || echo hwmon)"
        case "$name" in
            nvme|drivetemp) continue ;;
            *pmbus*|*dps[0-9]*|*psu*) continue ;;
        esac
        for p in "$hw"/pwm*; do
            [[ -e "$p" ]] || continue
            bn="$(basename "$p")"
            [[ "$bn" =~ ^pwm[0-9]+$ ]] || continue
            [[ -w "${p}_enable" ]] || continue
            found=1
            if echo 2 > "${p}_enable" 2>/dev/null; then :; else
                echo 0 > "${p}_enable" 2>/dev/null || true
            fi
            mode="$(cat "${p}_enable" 2>/dev/null || echo '?')"
            log_echo "Restored ${p}_enable (${name}) to ${mode} (2=automatic, 0=full speed)."
        done
    done
    if (( found == 0 )); then
        log_echo "No fan-controller PWM channels found to restore."
    fi
}

# run forever in service mode, run once in manual mode (to see output)
if $RESTORE; then
    restore_auto
elif $SERVICE; then
    while true; do
        set_fan_speed
        sleep 60
    done
else
    set_fan_speed
fi
