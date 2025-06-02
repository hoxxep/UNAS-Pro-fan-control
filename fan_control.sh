#!/bin/bash

# Fan control service for a UNAS Pro.

set -euo pipefail

# TGT = desired healthy temp in Celcius to run at 15% fans
# MAX = unhealthy temp to run at 100% fans
# Fan speed will be set linearly based on the actual temp between TGT and MAX.
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
    hdd_devices=(sda sdb sdc sdd sde sdf sdg)

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

    # Set fan speed
    echo $FAN_SPEED > /sys/class/hwmon/hwmon0/pwm1
    echo $FAN_SPEED > /sys/class/hwmon/hwmon0/pwm2

    # Confirm fan speed
    if $LOGGING; then
        echo "Confirming fan speeds are set to ${FAN_SPEED}"
        cat /sys/class/hwmon/hwmon0/pwm1
        cat /sys/class/hwmon/hwmon0/pwm2
    fi
}

if $SERVICE; then
    while true; do
        set_fan_speed
        sleep 60
    done
else
    set_fan_speed
fi
