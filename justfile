k3s_version := "v1.34.6+k3s1"

# List all available recipes
default:
    @just --list

bootstrap-gondor:
    ssh gondor 'K3S_VERSION={{k3s_version}} bash -s' < gondor/bootstrap/install-k3s.sh

# Pre-flight check that Flux can install on the current cluster
flux-check:
    flux check --pre

# Bootstrap Flux against pseudo/homelab (run once)
# Requires: export GITHUB_TOKEN=ghp_...
bootstrap-flux:
    @if [ -z "$GITHUB_TOKEN" ]; then \
        echo "ERROR: GITHUB_TOKEN must be set"; \
        echo "Generate at https://github.com/settings/tokens (classic, scope: repo)"; \
        exit 1; \
    fi
    bash gondor/bootstrap/bootstrap-flux.sh

# --- Day-to-day ---

# Force Flux to reconcile everything now (rather than waiting for the interval)
reconcile:
    flux reconcile source git flux-system
    flux reconcile kustomization flux-system

# Show all Flux resources at a glance
status:
    @echo "=== Sources ==="
    @flux get sources all -A
    @echo
    @echo "=== Kustomizations ==="
    @flux get kustomizations -A
    @echo
    @echo "=== Helm Releases ==="
    @flux get helmreleases -A

# Tail Flux logs (kustomize-controller is usually what you want)
logs component="kustomize-controller":
    kubectl logs -n flux-system -l app={{component}} --tail=100 -f

# Open Grafana (port-forward; run after kube-prometheus-stack is deployed)
grafana:
    @echo "Grafana at http://localhost:3000 — admin / prom-operator (default; change it)"
    kubectl -n monitoring port-forward svc/kube-prometheus-stack-grafana 3000:80

# Install unattended-upgrades on all Debian-based guests
# (run once per guest; idempotent if re-run)
setup-unattended-upgrades:
    #!/usr/bin/env bash
    set -euo pipefail
    SCRIPT="utility/setup-unattended-upgrades.sh"

    echo "=== gondor ==="
    scp "$SCRIPT" gondor:/tmp/setup-uu.sh
    ssh gondor 'sudo bash /tmp/setup-uu.sh && rm /tmp/setup-uu.sh'

    echo
    echo "Pushing to LXCs via earendil..."
    scp "$SCRIPT" root@earendil:/tmp/setup-uu.sh
    for vmid in {{debian_lxcs}}; do
        echo
        echo "=== LXC $vmid ==="
        ssh root@earendil "pct push $vmid /tmp/setup-uu.sh /root/setup-uu.sh && pct exec $vmid -- bash /root/setup-uu.sh && pct exec $vmid -- rm /root/setup-uu.sh"
    done
    ssh root@earendil 'rm /tmp/setup-uu.sh'
    echo
    echo "✓ unattended-upgrades configured on all guests."

# --- Patching ---

# All Debian-based LXCs on earendil
debian_lxcs := "120 121 130 131 141"

# Patch a single LXC (usage: just patch-lxc 120)
patch-lxc vmid:
    @echo "Patching LXC {{vmid}}..."
    ssh root@earendil "pct exec {{vmid}} -- bash -c 'export DEBIAN_FRONTEND=noninteractive && apt update && apt -y upgrade && apt -y autoremove && apt clean'"

# Patch all Debian LXCs sequentially
patch-lxcs:
    #!/usr/bin/env bash
    set -euo pipefail
    for vmid in {{debian_lxcs}}; do
        just patch-lxc $vmid
    done

# Patch the Debian VM (gondor) directly via SSH
patch-gondor:
    @echo "Patching gondor..."
    ssh gondor 'sudo bash -c "export DEBIAN_FRONTEND=noninteractive && apt update && apt -y upgrade && apt -y autoremove && apt clean"'

# Patch the Proxmox host itself
patch-earendil:
    @echo "Patching earendil (Proxmox host)..."
    ssh root@earendil 'apt update && apt -y dist-upgrade && apt -y autoremove'

# Patch everything that takes apt: Proxmox host, all LXCs, gondor VM
# Bazzite (anduril) is handled separately via rpm-ostree
patch-all: patch-earendil patch-lxcs patch-gondor
    @echo
    @echo "All apt-based hosts patched."
    @echo "Reminder: anduril (Bazzite) updates via rpm-ostree — use 'just patch-bazzite' when it's running."

# Patch Bazzite (anduril) — only works while the VM is running
# Bazzite uses rpm-ostree for atomic, transactional updates
patch-bazzite:
    @echo "Patching anduril (Bazzite)..."
    @echo "Note: this stages an update; reboot anduril to apply."
    ssh anduril 'rpm-ostree upgrade'

# Check pending reboots across all apt-based hosts
# (Returns nothing if no reboot is pending)
check-reboots:
    #!/usr/bin/env bash
    echo "=== earendil ==="
    ssh root@earendil 'test -f /var/run/reboot-required && cat /var/run/reboot-required.pkgs || echo "no reboot needed"'
    echo
    for vmid in {{debian_lxcs}}; do
        echo "=== LXC $vmid ==="
        ssh root@earendil "pct exec $vmid -- bash -c 'test -f /var/run/reboot-required && cat /var/run/reboot-required.pkgs || echo \"no reboot needed\"'"
    done
    echo
    echo "=== gondor ==="
    ssh gondor 'test -f /var/run/reboot-required && cat /var/run/reboot-required.pkgs || echo "no reboot needed"'