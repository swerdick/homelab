#!/usr/bin/env bash
# Setup script for the aglarond LXC (131)
# Run from inside the container as root: bash setup.sh

set -euo pipefail

if [[ "$(hostname)" != "aglarond" ]]; then
    echo "ERROR: this script is for the 'nfs' LXC; got hostname '$(hostname)'"
    exit 1
fi

bash "$(dirname "$0")/../scripts/setup-unattended-upgrades.sh"