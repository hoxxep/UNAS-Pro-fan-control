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

scp fan_control.sh "${HOST}:/root/fan_control.sh"
scp fan_control.service "${HOST}:/etc/systemd/system/fan_control.service"

ssh "$HOST" -t '\
    chmod +x /root/fan_control.sh && \
    systemctl daemon-reload && \
    systemctl enable fan_control.service && \
    systemctl restart fan_control.service && \
    systemctl status fan_control.service'
