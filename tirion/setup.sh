#!/usr/bin/env bash
# Setup script for the tirion LXC (141)
# Run from inside the container as root: bash setup.sh

set -euo pipefail

if [[ "$(hostname)" != "tirion" ]]; then
    echo "ERROR: this script is for the 'tirion' LXC; got hostname '$(hostname)'"
    exit 1
fi

bash "$(dirname "$0")/../scripts/setup-unattended-upgrades.sh"