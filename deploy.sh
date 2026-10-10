#!/usr/bin/env bash

# Install the fan control service onto a UNAS/UNVR from THIS checkout, over SSH.
# Run on your own machine, not the device.
#
#   ./deploy.sh root@unas                   # asks for the setpoints
#   ./deploy.sh root@unas --hdd 38          # or pass them, as for install.sh
#
# install.sh runs on the device and downloads the published files from GitHub;
# this is the same install, but with the files from your local checkout, for
# trying out changes before (or without) publishing them. It copies install.sh
# and the files it fetches into a temporary directory on the device, runs
# install.sh against them with RAW_URL=file://..., and removes them again.
#
# Repo: https://github.com/hoxxep/UNAS-Pro-fan-control
# Author: Liam Gray
# License: MIT

set -euo pipefail

# install.sh and everything it downloads from RAW_URL.
FILES=(install.sh fan_control.py fan_sensors.sh)

die() { echo "error: $*" >&2; exit 1; }

if [ $# -eq 0 ] || [ "$1" = "--help" ] || [ "$1" = "-h" ]; then
    cat <<'EOF'
Usage: deploy.sh [user@]host [install.sh options]

Installs the fan control service onto the device from this checkout rather
than from GitHub. Options after the host go to install.sh unchanged; with none
it asks for each setpoint. Run `bash install.sh --help` to list them.
EOF
    [ $# -eq 0 ] && exit 1 || exit 0
fi

HOST="$1"
shift

cd "$(dirname "$0")"
for f in "${FILES[@]}"; do
    [ -f "$f" ] || die "$f not found; run this from a checkout of the repo"
done

# Share one SSH connection between the copy and the install below, so a
# passphrase, password, or SSH agent approval is only asked for once.
ctl_dir="$(mktemp -d /tmp/fan_control_deploy.XXXXXX)"
ssh_opts=(-o ControlMaster=auto -o "ControlPath=${ctl_dir}/ssh" -o ControlPersist=60)
cleanup() {
    ssh "${ssh_opts[@]}" -O exit "$HOST" 2>/dev/null || true
    rm -rf "$ctl_dir"
}
trap cleanup EXIT

# tar over ssh rather than scp, so the device can make its own temporary
# directory and unpack into it in the one connection, printing where it put
# them. Plain ustar with COPYFILE_DISABLE keeps macOS from adding ._* files and
# xattr headers that GNU tar on the device would warn about.
echo "==> Copying ${FILES[*]} to ${HOST}"
remote_dir="$(
    COPYFILE_DISABLE=1 tar --format=ustar -cf - "${FILES[@]}" \
        | ssh "${ssh_opts[@]}" "$HOST" '
            d="$(mktemp -d /tmp/fan_control_deploy.XXXXXX)" || exit 1
            tar -xf - -C "$d" || { rm -rf "$d"; exit 1; }
            echo "$d"'
)" || die "could not copy the files to ${HOST}"
[ -n "$remote_dir" ] || die "could not copy the files to ${HOST}"

# Re-quote install.sh's arguments for the remote shell. Only when there are
# some: printf would turn none into a single '' argument, and install.sh only
# asks for the setpoints when it is given no arguments at all.
install_args=""
if [ $# -gt 0 ]; then
    install_args="$(printf '%q ' "$@")"
fi

# -t so install.sh can prompt for the setpoints. The copied files are removed
# however it exits.
echo "==> Running install.sh on ${HOST}"
ssh "${ssh_opts[@]}" -t "$HOST" \
    "trap 'rm -rf ${remote_dir}' EXIT; RAW_URL=file://${remote_dir} bash ${remote_dir}/install.sh ${install_args}"
