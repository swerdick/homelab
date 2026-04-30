#!/usr/bin/env bash
# Setup script for the samba LXC (121)
# Run from inside the container as root: bash setup.sh

set -euo pipefail

if [[ "$(hostname)" != "smb" ]]; then
    echo "ERROR: this script is for the 'nfs' LXC; got hostname '$(hostname)'"
    exit 1
fi

bash "$(dirname "$0")/../scripts/setup-unattended-upgrades.sh"