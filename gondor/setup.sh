#!/usr/bin/env bash
# Setup script for gondor (Debian VM, k3s host)
# Run from inside the VM as root: sudo bash setup.sh

set -euo pipefail

if [[ "$(hostname)" != "gondor" ]]; then
    echo "ERROR: this script is for gondor; got hostname '$(hostname)'"
    exit 1
fi

sudo bash "$(dirname "$0")/../scripts/setup-unattended-upgrades.sh"