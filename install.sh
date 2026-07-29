#!/usr/bin/env bash

# Install the UNAS/UNVR fan control service. Run ON the device, as root.
#
# Lowers the PID setpoints of UniFi OS's own fan controller (uhwd) and installs
# a systemd unit to re-apply them at every boot, since config.fan is volatile.
#
#   curl -fsSL $REPO/install.sh | bash                  # asks for the setpoints
#   curl -fsSL $REPO/install.sh | bash -s -- --hdd 40   # or pass them
#
# Re-run it to retune. To remove, see uninstall.sh.
#
# Repo: https://github.com/hoxxep/UNAS-Pro-fan-control
# Author: Liam Gray
# License: MIT

set -euo pipefail

# Point this at a local checkout or web server to test unreleased changes, e.g.
#   RAW_URL=file:///root/fan-test bash /root/fan-test/install.sh
RAW_URL="${RAW_URL:-https://raw.githubusercontent.com/hoxxep/UNAS-Pro-fan-control/refs/heads/main}"
PY_PATH=/root/fan_control.py
SENSORS_PATH=/root/sensors.sh
UNIT_NAME=fan_control.service
UNIT_PATH="/etc/systemd/system/${UNIT_NAME}"
# The pre-uhwd version of this project, replaced by PY_PATH under the same unit
# name. See the migration step further down.
OLD_SH_PATH=/root/fan_control.sh

die() { echo "error: $*" >&2; exit 1; }

# Arguments are passed through to fan_control.py verbatim, so the setpoints are
# defined in exactly one place rather than being re-declared here.
if [ "${1:-}" = "--help" ] || [ "${1:-}" = "-h" ]; then
    cat <<'EOF'
Usage: install.sh [fan_control.py options]

Lowers uhwd's fan PID setpoints and installs a systemd unit that re-applies
them at boot. Re-run it to retune. With no options it asks for each setpoint,
offering the default; pass any option to skip the questions.

  --cpu C    CPU setpoint in degrees C (stock 83)
  --hdd C    HDD setpoint in degrees C (stock 48). The one worth tuning:
             lower is cooler and louder.
  --nvme C   NVMe setpoint in degrees C (stock 60), on the models that
             have one. Left at stock by default.
  --idle N   Fan output when idle, 0-100 (stock 15). A minimum, not a cap;
             raising it only makes the box louder at idle.

To remove, run uninstall.sh.
EOF
    exit 0
fi

[ "$(id -u)" -eq 0 ] || die "must run as root on the UNAS/UNVR itself"
command -v systemctl >/dev/null || die "systemctl not found; is this a UniFi OS device?"

echo "==> Downloading fan_control.py"
curl -fsSL "${RAW_URL}/fan_control.py" -o "$PY_PATH" \
    || die "could not download ${RAW_URL}/fan_control.py"
chmod +x "$PY_PATH"

# sensors.sh comes along for the ride: it is the tool for checking what the
# setpoints actually did, and anyone running this installer is on the device
# with no checkout to pipe it from. Read-only and not needed by the service, so
# a failed download is a warning rather than a dead install.
echo "==> Downloading sensors.sh"
if curl -fsSL "${RAW_URL}/sensors.sh" -o "$SENSORS_PATH"; then
    chmod +x "$SENSORS_PATH"
else
    rm -f "$SENSORS_PATH"
    echo "    warning: could not download ${RAW_URL}/sensors.sh -- skipping it." >&2
    echo "    It is only a read-only diagnostic; the install continues." >&2
fi

read -r def_cpu def_hdd def_idle def_nvme < <(python3 "$PY_PATH" --defaults) \
    || die "could not read the defaults from ${PY_PATH}"

# What the fans are being run to right now, for the "current" column below. Read
# from the live config rather than hardcoded here, so a re-run shows what the
# last install set. cur_nvme is empty on models with no NVMe category.
read -r cur_cpu cur_hdd cur_idle cur_nvme < <(python3 "$PY_PATH" --current) \
    || die "could not read the current values from ${PY_PATH}"

# Ask only when there is a terminal to ask on and nothing was passed. When this
# script is piped from curl, stdin is the script itself, so prompts have to go
# via /dev/tty. Probe it by actually opening it: with no controlling terminal
# (cron, a non-interactive ssh command) `test -r` still passes but the open
# fails, which would spray errors and then fall back to the defaults anyway.
interactive=false
if [ $# -eq 0 ] && (exec 3<>/dev/tty) 2>/dev/null; then
    interactive=true
fi

# Two columns: what the box does now vs what we are about to set it to, with
# the value in brackets being the one you get by pressing enter.
ask() {
    local prompt=$1 current=$2 default=$3 reply
    printf '  %-28s %7s   [%s]: ' "$prompt" "$current" "$default" > /dev/tty
    read -r reply < /dev/tty || reply=""
    printf '%s' "${reply:-$default}"
}

args=("$@")
while true; do
    if [ "$interactive" = true ]; then
        echo
        echo "Setpoints -- press enter to accept the recommended value."
        printf '  %-28s %7s   %s\n' "" "current" "new"
        cpu=$(ask "Target CPU temperature in C" "$cur_cpu" "$def_cpu")
        hdd=$(ask "Target HDD temperature in C" "$cur_hdd" "$def_hdd")
        args=(--cpu "$cpu" --hdd "$hdd")
        # Only worth asking about on the models that have it.
        if [ -n "$cur_nvme" ]; then
            nvme=$(ask "Target NVMe temperature in C" "$cur_nvme" "$def_nvme")
            args+=(--nvme "$nvme")
        fi
        idle=$(ask "Minimum fan speed, 0-100" "$cur_idle" "$def_idle")
        args+=(--idle "$idle")
        echo
    elif [ ${#args[@]} -eq 0 ]; then
        args=(--cpu "$def_cpu" --hdd "$def_hdd" --idle "$def_idle")
    fi

    # Dry-run fan_control.py with these arguments before baking them into the
    # unit: it validates them (so this script needs no knowledge of them) and
    # shows the change that is about to be made.
    echo "==> Checking the requested setpoints (read-only)"
    if output=$(python3 "$PY_PATH" "${args[@]}" 2>&1) && grep -q '^Proposed' <<<"$output"; then
        echo "$output"
        break
    fi

    echo "$output" >&2
    [ "$interactive" = true ] \
        || die "fan_control.py rejected these setpoints; nothing has been changed"
    echo "Those setpoints were rejected -- try again." >&2
done

# Clean up after the previous version of this project, which drove the PWM
# channels directly from /root/fan_control.sh under this same unit name. Done
# only once the setpoints above have been validated, so an abandoned install
# leaves the old setup running rather than half-removed.
#
# Order matters: the old unit has to be stopped while systemd still knows its
# definition, because the daemon-reload below replaces it (along with its
# `ExecStopPost=... --restore` hook) with ours.
if [ -f "$OLD_SH_PATH" ]; then
    if grep -q 'UNAS-Pro-fan-control' "$OLD_SH_PATH" 2>/dev/null; then
        echo "==> Removing ${OLD_SH_PATH} from the previous version of this project"
        systemctl stop "$UNIT_NAME" 2>/dev/null || true
        # The old script held the fans in manual mode; hand them back before
        # uhwd resumes, in case the ExecStopPost hook did not run.
        bash "$OLD_SH_PATH" --restore >/dev/null 2>&1 || true
        rm -f "$OLD_SH_PATH"
        echo "    Stopped it, handed the fans back to uhwd, and removed the script."
    else
        # Not ours: leave it alone, but say so, since the unit is about to be
        # overwritten and may well be what runs it.
        echo "==> Note: ${OLD_SH_PATH} exists but is not from this project."
        echo "    Leaving it in place; ${UNIT_NAME} is about to be replaced."
    fi
fi

echo "==> Writing ${UNIT_PATH}"
cat > "$UNIT_PATH" <<EOF
# Fan control service for a UNAS/UNVR. Generated by install.sh -- re-run the
# installer to change the setpoints rather than editing this file.
#
# Retunes UniFi OS's own fan controller (uhwd) at boot by rewriting its PID
# setpoints in the Status Database. config.fan is volatile: uhwd re-initialises
# it to the stock defaults on every full reboot, so this unit exists purely to
# re-apply the setpoints once uhwd is up.
#
# Repo: https://github.com/hoxxep/UNAS-Pro-fan-control
# License: MIT

[Unit]
Description=Retune UniFi OS Fan Controller Setpoints
# uhwd owns config.fan, so it must be running before we can read/write it.
After=multi-user.target uhwd.service
Wants=uhwd.service
# uhwd (and the status DB behind it) can take a while to publish config.fan
# after boot. Allow plenty of retries before systemd gives up on the unit.
StartLimitIntervalSec=600
StartLimitBurst=20

[Service]
Type=oneshot
# Applies the setpoints and restarts uhwd itself to pick them up.
ExecStart=/usr/bin/python3 ${PY_PATH} --write ${args[*]}
# Keep the unit "active" after the one-shot exits, so \`systemctl status\` shows
# whether the setpoints were applied on this boot.
RemainAfterExit=yes
# If config.fan isn't published yet, the script exits non-zero; retry until it is.
Restart=on-failure
RestartSec=15
User=root
# Nothing to undo on stop: the setpoints simply stay until the next reboot
# re-initialises config.fan (or you switch fan presets in the UniFi UI).

[Install]
WantedBy=multi-user.target
EOF

echo "==> Enabling and starting ${UNIT_NAME}"
systemctl daemon-reload
systemctl enable "$UNIT_NAME"
# `enable --now` will not restart an already-enabled unit, so be explicit --
# this is also the path a re-run takes when retuning.
systemctl restart "$UNIT_NAME"
systemctl --no-pager status "$UNIT_NAME" || true

cat <<EOF

Installed.

  Check      python3 ${PY_PATH}
  Sensors    ${SENSORS_PATH}
  Retune     re-run this installer
  Uninstall  curl -fsSL ${RAW_URL}/uninstall.sh | bash

Give it 10-15 minutes before judging temperatures; the PID takes time to settle.
Note that switching the fan preset in the UniFi UI reverts these setpoints --
run \`systemctl restart ${UNIT_NAME}\` afterwards to re-apply them.
EOF
