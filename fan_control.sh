#!/bin/bash

# Fan control service for a UNAS Pro.
#
# Run directly as /root/fan_control.sh to query current temps and computed fan speeds.
# Use the --service flag to loop once per minute and prevent logging to stdout.
#
# Repo: https://github.com/hoxxep/UNAS-Pro-fan-control
# Author: Liam Gray
# License: MIT

set -euo pipefail

# TGT = desired healthy temp in Celcius to run at 15% fans
# MAX = unhealthy temp to run at 100% fans
# Fan speed will be set linearly based on the current temp between TGT and MAX.
# See README.md for tips on configuring these arguments.
CPU_TGT=50
CPU_MAX=70
HDD_TGT=32
HDD_MAX=50
MIN_FAN=39  # 15% of 255 (increase baseline to reduce fan speed variation)

# SERVICE=true: loop once every 60s to set fan speed and temp, no LOGGING
# SERVICE=false: run once, logging temps and fan speed to console
LOGGING=true
SERVICE=false
if [ "${1:-}" = "--service" ]; then
    LOGGING=false
    SERVICE=true
fi

log_echo() {
    if $LOGGING; then
        echo "$@"
    fi
}

set_fan_speed() {
    # List of various temp sensors
    cpu_devices=("hwmon/hwmon0/temp1_input" "hwmon/hwmon0/temp2_input" "hwmon/hwmon0/temp3_input" "thermal/thermal_zone0/temp")

    # Initialise maximum CPU temperature
    CPU_TEMP=0

    # Loop through each sensor to get the temperature
    for dev in "${cpu_devices[@]}"; do
        # Read CPU temperature (in millidegrees Celsius)
        temp=$(cat "/sys/class/$dev")
        temp=$((temp / 1000))
        log_echo "/sys/class/$dev CPU Temperature: ${temp}ºC"
        if [[ "$temp" =~ ^[0-9]+$ ]] && [ "$temp" -gt "$CPU_TEMP" ]; then
            CPU_TEMP=$temp
        fi
    done

    # List of HDD devices
    hdd_devices=(sda sdb sdc sdd sde sdf sdg sdh)

    # Initialize maximum HDD temperature
    HDD_TEMP=0

    # Loop through each HDD and get the temperature
    for dev in "${hdd_devices[@]}"; do
        if smartctl -a "/dev/$dev" &>/dev/null; then
            temp=$(smartctl -a "/dev/$dev" | awk '/194 Temperature_Celsius/ {print $10}')
            log_echo "/dev/$dev HDD Temperature: ${temp}°C"
            if [[ "$temp" =~ ^[0-9]+$ ]] && [ "$temp" -gt "$HDD_TEMP" ]; then
                HDD_TEMP=$temp
            fi
        fi
    done

    # Function to calculate fan curve
    fan_curve() {
        local min=$1
        local actual=$2
        local max=$3

        fan_speed=$(awk -v min="$min" -v actual="$actual" -v max="$max" '
        BEGIN {
            if (actual <= min) {
                ratio = 0
            } else if (actual >= max) {
                ratio = 1
            } else {
                ratio = (actual - min) / (max - min)
            }
            if (ratio < 0) ratio = 0
            if (ratio > 1) ratio = 1
            printf "%d", ratio * 255
        }')
        echo $fan_speed
    }

    # Calculate fan speeds
    HDD_FAN=$(fan_curve "$HDD_TGT" "$HDD_TEMP" "$HDD_MAX")
    CPU_FAN=$(fan_curve "$CPU_TGT" "$CPU_TEMP" "$CPU_MAX")

    # Take the maximum of HDD_FAN and CPU_FAN
    FAN_SPEED=$(( HDD_FAN > CPU_FAN ? HDD_FAN : CPU_FAN ))
    FAN_SPEED=$(( MIN_FAN > FAN_SPEED ? MIN_FAN : FAN_SPEED ))

    # Output the values
    log_echo "Max HDD Temperature: ${HDD_TEMP}°C"
    log_echo "CPU Temperature: ${CPU_TEMP}°C"

    log_echo "Min Fan Speed: ${MIN_FAN}"
    log_echo "HDD Fan Speed: ${HDD_FAN}"
    log_echo "CPU Fan Speed: ${CPU_FAN}"
    log_echo "Final Fan Speed (Max): ${FAN_SPEED}"

    # List of potential fan devices
    fan_dir="/sys/class/hwmon/hwmon0"
    fan_devices=(pwm1 pwm2 pwm3 pwm4)
    FAN_FOUND=0

    # Loop through each fan to set the speed
    for fan in "${fan_devices[@]}"; do
        fan_file="${fan_dir}/${fan}"
        if [[ -e "$fan_file" ]]; then
            FAN_FOUND=1
            echo $FAN_SPEED > "$fan_file"

            # Confirm fan speed
            if $LOGGING; then
                FAN_SPEED_SET_TO=$(cat "$fan_file")
                echo "Fan $fan_file has been set to ${FAN_SPEED}/255, and is reading as ${FAN_SPEED_SET_TO}/255."
            fi
        fi
    done

    # If no fan devices found, log a clear error and exit
    if (( FAN_FOUND == 0 )); then
        echo "No fan devices found at: ${fan_dir}*"
        exit 1
    fi
}

# run forever in service mode, run once in manual mode (to see output)
if $SERVICE; then
    while true; do
        set_fan_speed
        sleep 60
    done
else
    set_fan_speed
fi
