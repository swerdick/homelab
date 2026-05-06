k3s_version := "v1.34.6+k3s1"

# All Debian-based LXCs on earendil
debian_lxcs := "120 121 130 131 141"

# List all available recipes
default:
    @just --list

# --- Bootstrap ---

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

# Watch Kustomization reconciliations live (Ctrl+C to exit)
flux-monitor:
    flux get kustomizations -A --watch

# Stream all Flux events in real time (Ctrl+C to exit)
events:
    flux events -A --watch

# Tail Flux logs (kustomize-controller is usually what you want)
logs component="kustomize-controller":
    kubectl logs -n flux-system -l app={{component}} --tail=100 -f

# Validate Kubernetes manifests via server-side dry-run.
# Auto-detects SOPS-encrypted files and decrypts them before validation.
validate path:
    #!/usr/bin/env bash
    set -euo pipefail
    rendered=$(kustomize build {{path}})
    # SOPS-encrypted resources have an inline 'sops:' block at the top level
    # which kubectl's strict decoder rejects. Detect and route through sops.
    if echo "${rendered}" | grep -q "^sops:" || echo "${rendered}" | grep -q "ENC\[AES256_GCM"; then
        echo "(SOPS-encrypted resources detected — decrypting before validation)"
        find {{path}} -name "*.yaml" -not -name "kustomization.yaml" | while read -r f; do
            if grep -q "^sops:" "$f" 2>/dev/null; then
                sops --decrypt "$f" | kubectl apply --dry-run=server -f -
            else
                kubectl apply --dry-run=server -f "$f"
            fi
        done
    else
        echo "${rendered}" | kubectl apply --dry-run=server -f -
    fi

# Encrypt a Kubernetes Secret YAML in place using SOPS+age.
# The .sops.yaml at the repo root configures which fields get encrypted
# (currently: data: and stringData: under any gondor/*.yaml).
#
# Workflow for adding a new encrypted Secret:
#   1. Write a plaintext Secret manifest with actual values
#   2. just sops-encrypt path/to/secret.yaml
#   3. Add the file to its parent kustomization.yaml's resources list
#   4. git add, commit, push — Flux decrypts and applies in-cluster
sops-encrypt path:
    @sops --encrypt --in-place {{path}}
    @echo ""
    @echo "✓ Encrypted in place: {{path}}"
    @echo ""
    @echo "Don't forget to:"
    @echo "  1. Add this file to its parent kustomization.yaml's 'resources:' list"
    @echo "  2. just validate <kustomization-dir>  to confirm it dry-runs cleanly"
    @echo "  3. git add, commit, push — Flux will decrypt and apply"
    @echo ""
    @echo "To re-edit the secret later:"
    @echo "  sops {{path}}    # opens decrypted in your \$EDITOR"

# Open Grafana (port-forward; run after kube-prometheus-stack is deployed)
grafana:
    @echo "Grafana at http://localhost:3000 — admin / prom-operator (default; change it)"
    kubectl -n monitoring port-forward svc/kube-prometheus-stack-grafana 3000:80

# Open Capacitor (Flux UI) on http://localhost:9000
capacitor:
    @echo "Capacitor will be available at http://localhost:9000"
    kubectl -n flux-system port-forward svc/capacitor 9000:9000

# --- Patching ---

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

# --- CA / TLS ---

# Trust the Vingilot root CA in this Mac's System Keychain.
# Run once per fresh Mac, and again after a CA rotation.
# (Linux hosts are handled by ansible/playbooks/distribute-root-ca.yaml.)
trust-ca-mac:
    @echo "Adding ansible/files/vingilot-root-ca.crt to System Keychain..."
    @echo "(You'll be prompted for sudo and Keychain admin auth.)"
    sudo security add-trusted-cert -d -r trustRoot -k /Library/Keychains/System.keychain ansible/files/vingilot-root-ca.crt
    @echo
    @echo "✓ Trusted on this Mac."
    @echo
    @echo "Firefox uses its own NSS trust store. To make it follow the system trust:"
    @echo "  about:config -> security.enterprise_roots.enabled = true"
    @echo "  Restart Firefox afterward."

# --- Setup tasks ---

# Configure unattended-upgrades on all Debian guests via ansible
# (idempotent; safe to re-run)
setup-unattended-upgrades:
    ansible-playbook -i ansible/inventory.yaml ansible/playbooks/install-unattended-upgrades.yaml

# Install/bootstrap step-ca on tirion via ansible. Idempotent — once the CA
# is initialized this is a no-op. Targets only tirion.
setup-step-ca:
    ansible-playbook -i ansible/inventory.yaml ansible/playbooks/install-step-ca.yaml
