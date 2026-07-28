#!/bin/bash

# Sensor discovery for UNAS/UNVR devices.
#
# READ-ONLY: dumps every hwmon chip, thermal zone, and fan/PWM channel together
# with its kernel name and label, plus each SMART drive's temperature as
# fan_control.sh reads it. It does NOT change any fan speed. Use it to see
# exactly what each temperature sensor, drive, and fan is, so fan_control.sh can
# map them correctly across the device range (UNAS 2 ... EUNAS/ENVR).
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
    # The enable flag matters for safety, but note mode 1 (manual) is shared: it
    # is used both by fan_control.sh AND by UniFi OS's own fan daemon on newer
    # builds, so mode 1 alone does not tell you which one is driving the speed.
    # Run `fan_control.sh --restore` to hand control back (to the chip curve or
    # the UniFi daemon, whichever the firmware supports).
    for p in "$h"/pwm*; do
        [[ -e "$p" ]] || continue
        bn="$(basename "$p")"
        [[ "$bn" =~ ^pwm[0-9]+$ ]] || continue
        en="$(read_raw "${p}_enable")"
        case "$en" in
            0)  mode="no SW control / full speed" ;;
            1)  mode="manual (fan_control.sh or UniFi OS daemon)" ;;
            \?) mode="" ;;
            *)  mode="automatic / chip curve" ;;
        esac
        printf "   %-12s val=%-4s enable=%-2s %s\n" "$bn" "$(read_raw "$p")" "$en" "$mode"
    done
done

echo
echo "------------------------------------------------------------------"
echo "pwm enable legend:  0 = no software control (firmware/full speed)"
echo "                    1 = manual (fan_control.sh OR UniFi OS fan daemon)"
echo "                    2+ = automatic / chip thermal curve (rejected on some"
echo "                         newer UniFi OS builds, which do fan control in SW)"
echo "------------------------------------------------------------------"

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
echo "=================================================================="
echo " drives             smartctl --scan-open"
echo "   (HDD/SSD temps as fan_control.sh sees them, via SMART)"
echo "=================================================================="
if ! command -v smartctl >/dev/null 2>&1; then
    echo "   smartctl not found (install smartmontools) - skipping drives."
elif ! command -v jq >/dev/null 2>&1; then
    echo "   jq not found - skipping drives (fan_control.sh needs jq too)."
else
    scan="$(smartctl --json=c --scan-open 2>/dev/null || true)"
    found=0
    while IFS=$'\t' read -r dev dtype; do
        [[ -n "$dev" ]] || continue
        found=1

        args=(--json=c --all)
        [[ -n "$dtype" ]] && args+=(-d "$dtype")

        json="$(smartctl "${args[@]}" "$dev" 2>/dev/null || true)"
        if [[ -z "$json" ]]; then
            printf "   %-16s %5s      %s\n" "$dev" "?" "smartctl returned nothing"
            continue
        fi

        # Same temperature/class extraction as fan_control.sh get_disk_temps(),
        # plus the model/rotation so an unknown drive can be identified from the
        # output. Temperature is "?" here rather than dropped, so a drive that
        # reports no temperature is still visible as a drive fan_control.sh sees.
        line="$(jq -r '
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
            | [
                (device_class),
                ($temp // "?" | tostring),
                ((.model_name // .scsi_model_name // "?") | tostring),
                (if (.rotation_rate? // null) == null then ""
                 elif .rotation_rate == 0 then "non-rotating"
                 else "\(.rotation_rate) rpm"
                 end)
              ] | @tsv
        ' <<< "$json" 2>/dev/null || true)"

        if [[ -z "$line" ]]; then
            printf "   %-16s %5s      %s\n" "$dev" "?" "could not parse smartctl JSON"
            continue
        fi

        IFS=$'\t' read -r class temp model rpm <<< "$line"
        [[ "$temp" == "?" ]] || temp="${temp}°C"
        printf "   %-16s %6s  class=%-3s type=%-6s model=%s%s\n" \
            "$dev" "$temp" "$class" "${dtype:-auto}" "$model" \
            "${rpm:+ ($rpm)}"
    done < <(jq -r '.devices[]? | [.name, (.type // "")] | @tsv' <<< "$scan" 2>/dev/null)

    if (( found == 0 )); then
        echo "   No SMART devices found by 'smartctl --scan-open'."
    fi
fi
