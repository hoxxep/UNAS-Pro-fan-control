#!/bin/bash

# Run remotely to query UNAS Pro temps and fan speed.

set -euo pipefail

HOST="$1"

ssh "$HOST" -t '/root/fan_control.sh'
