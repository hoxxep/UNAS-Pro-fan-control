#!/bin/bash

# Run remotely to query UNAS Pro temps and fan speed.
#
# Repo: https://github.com/hoxxep/UNAS-Pro-fan-control
# Author: Liam Gray
# License: MIT

set -euo pipefail

HOST="$1"

ssh "$HOST" -t '/root/fan_control.sh'
