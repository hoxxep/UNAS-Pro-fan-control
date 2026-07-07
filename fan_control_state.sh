#!/bin/bash

# Optional MQTT-bridge hooks for fan_control.sh.
#
# When installed at /root/fan_control_state.sh, fan_control.sh sources it and
# calls apply_fan_conf / state_begin / state_add_drive / state_end on every
# loop iteration, replacing the no-op stubs it defines otherwise. The hooks:
#
#   apply_fan_conf    apply fan-curve overrides tuned from Home Assistant
#                     (written by mqtt_bridge.py to /root/fan_control.conf)
#   state_*           write an atomic JSON snapshot of temperatures, fan
#                     speeds, and tachometers to /run/fan_control/state.json
#                     (tmpfs) for mqtt_bridge.py to publish
#
# The snapshot is only written when /root/mqtt_bridge.conf exists, so without
# an MQTT setup this file adds a single file-existence check per loop.
#
# Failures here must never break fan control: the conf file is parsed against
# a strict key allowlist (never sourced, so it cannot execute code or crash
# the script), and state_end swallows all errors. jq errors are captured in
# /run/fan_control/jq_error for diagnosis instead of being discarded.
#
# Repo: https://github.com/hoxxep/UNAS-Pro-fan-control
# License: MIT

FAN_CONF=/root/fan_control.conf
BRIDGE_CONF=/root/mqtt_bridge.conf
STATE_DIR=/run/fan_control
STATE_FILE="$STATE_DIR/state.json"

# Apply fan-curve overrides from FAN_CONF. Only whitelisted keys with plain
# integer values in a sane range are accepted; anything else is ignored.
# Range checks matter for safety, not just hygiene: an absurdly large MIN_FAN
# reaching the awk fan curve causes float cancellation that computes a fan
# speed of 0 while overheating. Oversized files are skipped outright.
apply_fan_conf() {
    local k v size
    [[ -f "$FAN_CONF" ]] || return 0
    size=$(wc -c < "$FAN_CONF" 2>/dev/null) || return 0
    [[ "$size" =~ ^[[:space:]]*[0-9]+$ && $size -le 4096 ]] || return 0
    while IFS='=' read -r k v; do
        v="${v%$'\r'}"  # tolerate CRLF-edited files
        case "$k" in
            SYS_TGT|SYS_MAX|HDD_TGT|HDD_MAX|SSD_TGT|SSD_MAX)
                [[ "$v" =~ ^[0-9]{1,3}$ && $v -le 150 ]] && printf -v "$k" '%s' "$v" ;;
            MIN_FAN|MAX_FAN)
                [[ "$v" =~ ^[0-9]{1,3}$ && $v -le 255 ]] && printf -v "$k" '%s' "$v" ;;
        esac
    done < "$FAN_CONF" 2>/dev/null || true
    return 0
}

state_begin() {
    STATE_DRIVES=()
    STATE_ENABLED=0
    [[ -f "$BRIDGE_CONF" ]] && STATE_ENABLED=1
    return 0
}

# state_add_drive CLASS DEV TEMP SERIAL
state_add_drive() {
    STATE_DRIVES+=("$1"$'\t'"$2"$'\t'"$3"$'\t'"${4:-}")
    return 0
}

# Write the snapshot. Reads fan_control.sh globals: SYS_TEMP HDD_TEMP SSD_TEMP
# FAN_SPEED SYS_TGT SYS_MAX HDD_TGT HDD_MAX SSD_TGT SSD_MAX MIN_FAN MAX_FAN.
state_end() {
    (( ${STATE_ENABLED:-0} )) || return 0
    (
        set +e
        umask 077  # snapshot holds drive serials; keep it root-only
        mkdir -p "$STATE_DIR" 2>/dev/null || exit 0
        chmod 700 "$STATE_DIR" 2>/dev/null  # mkdir -p won't tighten a pre-existing dir

        # Collect tachometers from the same fan-controller chips
        # fan_control.sh drives (skip drive and PSU/PMBus chips). Keys are
        # "<chipname>_fanN"; a second chip with the same driver name gets a
        # "_2"/"_3" suffix so twin controllers cannot collide.
        local rows=() row hw name f v key n seen=" "
        for row in ${STATE_DRIVES[@]+"${STATE_DRIVES[@]}"}; do
            rows+=("D"$'\t'"$row")
        done
        for hw in /sys/class/hwmon/hwmon*; do
            [[ -e "$hw" ]] || continue
            name="$(cat "$hw/name" 2>/dev/null || echo hwmon)"
            case "$name" in
                nvme|drivetemp) continue ;;
                *pmbus*|*dps[0-9]*|*psu*) continue ;;
            esac
            for f in "$hw"/fan*_input; do
                [[ -e "$f" ]] || continue
                v="$(cat "$f" 2>/dev/null)"
                [[ "$v" =~ ^[0-9]+$ ]] || continue
                key="${name}_$(basename "${f%_input}")"
                if [[ "$seen" == *" $key "* ]]; then
                    n=2
                    while [[ "$seen" == *" ${key}_$n "* ]]; do n=$(( n + 1 )); done
                    key="${key}_$n"
                fi
                seen+="$key "
                rows+=("T"$'\t'"$key"$'\t'"$v")
            done
        done

        # Drive keys: serial number sanitized to [A-Za-z0-9_-] (stable across
        # /dev renames, and safe to embed in Home Assistant templates), with
        # the device basename as fallback when SMART reports no serial.
        # hdd_temp/ssd_temp are null when no drive of that class exists, so
        # the bridge can omit those sensors instead of reporting 0°C.
        printf '%s\n' ${rows[@]+"${rows[@]}"} | jq -R -s \
            --argjson sys_temp "${SYS_TEMP:-0}" \
            --argjson hdd_temp "${HDD_TEMP:-0}" \
            --argjson ssd_temp "${SSD_TEMP:-0}" \
            --argjson fan_speed "${FAN_SPEED:-0}" \
            --argjson sys_tgt "${SYS_TGT:-0}" --argjson sys_max "${SYS_MAX:-0}" \
            --argjson hdd_tgt "${HDD_TGT:-0}" --argjson hdd_max "${HDD_MAX:-0}" \
            --argjson ssd_tgt "${SSD_TGT:-0}" --argjson ssd_max "${SSD_MAX:-0}" \
            --argjson min_fan "${MIN_FAN:-0}" \
            --argjson max_fan "${MAX_FAN:-255}" '
            (split("\n") | map(select(length > 0) | split("\t"))) as $rows
            | ($rows | map(select(.[0] == "D"))) as $drows
            | {
                ts: (now | floor),
                sys_temp: $sys_temp,
                hdd_temp: (if ($drows | map(select(.[1] == "HDD")) | length) == 0
                           then null else $hdd_temp end),
                ssd_temp: (if ($drows | map(select(.[1] == "SSD")) | length) == 0
                           then null else $ssd_temp end),
                fan_speed_raw: $fan_speed,
                fan_duty_pct: (($fan_speed * 100 / 255) + 0.5 | floor),
                drives: ($drows | map({
                    key: ((if (.[4] // "") != "" then .[4]
                           else (.[2] | sub(".*/"; "")) end)
                          | gsub("[^A-Za-z0-9_-]"; "_")),
                    value: {class: .[1], dev: .[2], temp: (.[3] | tonumber)}
                }) | from_entries),
                tachs: ($rows | map(select(.[0] == "T")
                    | {key: .[1], value: (.[2] | tonumber)}) | from_entries),
                params: {
                    sys_tgt: $sys_tgt, sys_max: $sys_max,
                    hdd_tgt: $hdd_tgt, hdd_max: $hdd_max,
                    ssd_tgt: $ssd_tgt, ssd_max: $ssd_max,
                    min_fan: $min_fan, max_fan: $max_fan
                }
            }' > "$STATE_FILE.tmp" 2>"$STATE_DIR/jq_error" \
            && rm -f "$STATE_DIR/jq_error" \
            && mv "$STATE_FILE.tmp" "$STATE_FILE"
        exit 0
    ) || true
}
