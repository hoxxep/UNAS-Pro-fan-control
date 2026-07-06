#!/bin/bash

# Run remotely to deploy the fan control service onto a UNAS Pro.
#
# Usage: ./deploy.sh HOSTNAME
#
# Repo: https://github.com/hoxxep/UNAS-Pro-fan-control
# Author: Liam Gray
# License: MIT

set -euo pipefail

HOST="$1"

# The mqtt_bridge files are an optional MQTT/Home Assistant bridge, inert
# until /root/mqtt_bridge.conf is created on the device (see MQTT.md).
scp fan_control.sh fan_control_state.sh mqtt_bridge.py mqtt_bridge.conf.example "${HOST}:/root/"
scp fan_control.service mqtt_bridge.service "${HOST}:/etc/systemd/system/"

# The trailing status is informational only (|| true): mqtt_bridge.service is
# intentionally inactive without a conf, and systemctl status exits non-zero
# for inactive units; any real failure above still aborts via the && chain.
ssh "$HOST" -t '\
    chmod +x /root/fan_control.sh /root/mqtt_bridge.py && \
    systemctl daemon-reload && \
    systemctl enable fan_control.service && \
    systemctl restart fan_control.service && \
    systemctl enable mqtt_bridge.service && \
    systemctl restart mqtt_bridge.service && \
    { systemctl status fan_control.service mqtt_bridge.service || true; }'
