#!/usr/bin/env bash

# Remove the UNAS/UNVR fan control service and put the stock setpoints back.
# Run ON the device, as root.
#
#   curl -fsSL $REPO/uninstall.sh | bash
#
# The stock values come from the factory profile stored in config.fan, which
# this project never writes to, so this needs neither a reboot nor a trip
# through the UniFi UI.
#
# Repo: https://github.com/hoxxep/UNAS-Pro-fan-control
# Author: Liam Gray
# License: MIT

set -euo pipefail

PY_PATH=/root/fan_control.py
UNIT_NAME=fan_control.service
UNIT_PATH="/etc/systemd/system/${UNIT_NAME}"

die() { echo "error: $*" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || die "must run as root on the UNAS/UNVR itself"
command -v systemctl >/dev/null || die "systemctl not found; is this a UniFi OS device?"

echo "==> Stopping and disabling ${UNIT_NAME}"
systemctl disable --now "$UNIT_NAME" 2>/dev/null || true

# Restore before deleting the script that does the restoring.
restored=false
if [ -f "$PY_PATH" ]; then
    echo "==> Restoring the stock setpoints"
    if python3 "$PY_PATH" --restore --write; then
        restored=true
    fi
fi

echo "==> Removing files"
rm -f "$PY_PATH" "$UNIT_PATH"
systemctl daemon-reload

echo
if [ "$restored" = true ]; then
    cat <<EOF
Uninstalled. The stock fan setpoints are back and uhwd has been restarted, so
no reboot is needed. The fan preset shown in the UniFi UI is unchanged and is
once again the only thing driving the fans.
EOF
else
    cat <<EOF
Uninstalled, but the stock setpoints could NOT be restored automatically. To
get them back, either:

  - reboot the device, or
  - switch the fan profile in the UniFi OS UI.

Nothing is in a bad state meanwhile: uhwd is still the only thing driving the
fans, just with this project's setpoints until you do one of the above.
EOF
fi
