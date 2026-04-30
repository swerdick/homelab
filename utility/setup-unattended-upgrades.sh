#!/usr/bin/env bash
# scripts/setup-unattended-upgrades.sh
# Configures unattended-upgrades on a Debian-based guest.
# Idempotent — safe to re-run.

set -euo pipefail

# Confirm we're on Debian
if ! command -v apt-get >/dev/null; then
    echo "ERROR: this script requires apt (Debian/derivative)"
    exit 1
fi

if [[ $EUID -ne 0 ]]; then
    echo "ERROR: must run as root (use sudo)"
    exit 1
fi

# Detect Debian codename for the origins pattern below
CODENAME="$(. /etc/os-release && echo "$VERSION_CODENAME")"
echo "Configuring unattended-upgrades for Debian ${CODENAME}..."

export DEBIAN_FRONTEND=noninteractive

# Pick the right reboot-notifier package for the Debian release
if apt-cache show apt-config-auto-update >/dev/null 2>&1; then
    REBOOT_PKG="apt-config-auto-update"
else
    REBOOT_PKG="update-notifier-common"
fi

apt-get update
apt-get install -y unattended-upgrades "$REBOOT_PKG" apt-listchanges

# Main config: which origins to pull from, what to do
cat > /etc/apt/apt.conf.d/50unattended-upgrades <<EOF
// Managed by setup-unattended-upgrades.sh — edit the script, not this file

Unattended-Upgrade::Origins-Pattern {
    // Security updates only
    "origin=Debian,codename=\${distro_codename},label=Debian-Security";
    "origin=Debian,codename=\${distro_codename}-security,label=Debian-Security";
};

// Don't auto-upgrade these even if they have security updates
// (add packages here if something breaks during an auto-upgrade)
Unattended-Upgrade::Package-Blacklist {
};

// Remove unused kernels and dependencies
Unattended-Upgrade::Remove-Unused-Kernel-Packages "true";
Unattended-Upgrade::Remove-New-Unused-Dependencies "true";
Unattended-Upgrade::Remove-Unused-Dependencies "true";

// Treat conffile prompts conservatively — keep the version we have
Unattended-Upgrade::DPkg::Options {
    "--force-confdef";
    "--force-confold";
};

// Email config — we don't have local mail set up, leave empty
Unattended-Upgrade::Mail "";

// IMPORTANT: do not auto-reboot. Reboots are deliberate via 'just check-reboots'.
Unattended-Upgrade::Automatic-Reboot "false";

// Be quieter in syslog unless something fails
Unattended-Upgrade::Verbose "false";
Unattended-Upgrade::Debug "false";
EOF

# Enable the periodic timers (run apt update + unattended-upgrade daily)
cat > /etc/apt/apt.conf.d/20auto-upgrades <<EOF
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::AutocleanInterval "7";
APT::Periodic::Verbose "0";
EOF

# Make sure the timer is running
systemctl enable --now apt-daily.timer
systemctl enable --now apt-daily-upgrade.timer

echo
echo "✓ unattended-upgrades configured."
echo "  Config: /etc/apt/apt.conf.d/50unattended-upgrades"
echo "  Timers: apt-daily.timer, apt-daily-upgrade.timer"
echo
echo "Verify with:"
echo "  unattended-upgrade --dry-run --debug 2>&1 | head -50"
echo "  systemctl list-timers 'apt-*'"