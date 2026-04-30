#!/usr/bin/env bash
# Setup script for the erebor LXC (130)
# Run from inside the container as root: bash setup.sh

set -euo pipefail

if [[ "$(hostname)" != "erebor" ]]; then
    echo "ERROR: this script is for the 'erebor' LXC; got hostname '$(hostname)'"
    exit 1
fi

bash "$(dirname "$0")/../scripts/setup-unattended-upgrades.sh"