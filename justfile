# Lockstep with gondor/bootstrap/install-k3s.sh and
# ansible/host_vars/samwise.yaml — bump all three together until the
# "refactor install-k3s.sh to ansible" ROADMAP item collapses them.
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

# Patch Bazzite (anduril) — only works while the VM is running.
# Bazzite uses rpm-ostree for atomic, transactional updates.
#
# We call `rpm-ostree upgrade` directly rather than `ujust update`
# because anduril is a headless gaming VM: the "extras" ujust orchestrates
# (firmware, flatpak system/user, brew, gnome themes) are all no-ops here
# (no firmware in a VM, no flatpaks installed, brew is empty), and ujust's
# topgrade wrapper interactively prompts (R)eboot/(S)hell/(Q)uit at the
# end of every run — reading from /dev/tty directly, so even `ssh -n`
# can't suppress it. rpm-ostree upgrade is fully non-interactive.
#
# Pseudo can talk to rpmostreed directly thanks to the polkit rule we
# manage in setup-bazzite-base.yaml. No sudo / TTY needed.
#
# After staging, `verify-bazzite-staged` runs to confirm the new image
# hasn't removed anything we depend on (sunshine being the canonical
# example — Bazzite removed it from F44+; see project memory).
patch-bazzite:
    @echo "Patching anduril (Bazzite)..."
    @echo "Note: this stages an update; reboot anduril to apply."
    ssh anduril 'rpm-ostree upgrade'
    @echo
    @just verify-bazzite-staged

# Verify the currently-staged Bazzite deployment hasn't removed anything
# we critically depend on, and print version bumps for packages worth a
# glance. Run automatically by `patch-bazzite`; can also be invoked
# standalone any time there's a staged deployment to inspect.
#
# Exits non-zero if any package in CRITICAL is in the staged image's
# "Removed" set — making chained invocations fail loudly so we don't
# accidentally activate a broken upgrade.
verify-bazzite-staged:
    #!/usr/bin/env bash
    set -euo pipefail

    # Critical packages — removed from staged image == do not reboot.
    CRITICAL=(Sunshine)

    # Watch packages — print version changes for awareness, not gating.
    # Mix of fc43 ("kernel-nvidia-closed-lts") and fc44 ("kmod-nvidia")
    # package names so this works across Bazzite's packaging changes.
    WATCH=(
      Sunshine
      nvidia-driver
      kmod-nvidia
      kernel-nvidia-closed-lts
      kernel-core
      kernel
      sddm
      plasma-workspace
    )

    # Bail early if there's no staged deployment to verify.
    STAGED=$(ssh anduril 'rpm-ostree status --json' \
        | jq -r '.deployments[] | select(.staged==true) | .checksum // empty')
    if [ -z "$STAGED" ]; then
        echo "ℹ no staged Bazzite deployment — nothing to verify"
        exit 0
    fi

    DIFF=$(ssh anduril 'rpm-ostree db diff')
    REMOVED=$(echo "$DIFF"  | awk '/^Removed:$/{p=1;next}  /^[A-Z][a-z]+:$/{p=0} p')
    UPGRADED=$(echo "$DIFF" | awk '/^Upgraded:$/{p=1;next} /^[A-Z][a-z]+:$/{p=0} p')

    echo "Verifying staged Bazzite deployment ($STAGED)..."
    failed=0
    for pkg in "${CRITICAL[@]}"; do
        if echo "$REMOVED" | grep -qE "^  ${pkg}-"; then
            echo "  ✗ CRITICAL: '$pkg' is REMOVED in the staged upgrade"
            failed=1
        fi
    done
    [ "$failed" -eq 0 ] && echo "  ✓ all critical packages present"

    echo
    echo "Watch package version changes:"
    any=0
    for pkg in "${WATCH[@]}"; do
        line=$(echo "$UPGRADED" | grep -E "^  ${pkg} " || true)
        if [ -n "$line" ]; then
            echo "$line"
            any=1
        fi
    done
    [ "$any" -eq 0 ] && echo "  (no watched packages have version changes)"

    if [ "$failed" -eq 1 ]; then
        echo
        echo "✗ Staged upgrade is UNSAFE — DO NOT REBOOT."
        echo "  Discard the staged image with:"
        echo "    ssh anduril 'rpm-ostree cleanup --pending'"
        exit 1
    fi

    echo
    echo "✓ Staged upgrade looks safe."
    echo "  When ready to activate: ssh -t anduril 'sudo systemctl reboot'"

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

# --- PVE config snapshot ---

# Snapshot PVE guest configs (LXC + QEMU) from earendil into
# earendil/pve-configs/. Read-only documentation/audit trail — git diff
# after running shows what changed in the UI since the last snapshot.
#
# Cloudinit password hashes (`cipassword:` lines in qemu configs) are
# redacted before the local copy lands. Review the first dump for any
# other sensitive content before committing.
dump-pve-configs:
    #!/usr/bin/env bash
    set -euo pipefail
    mkdir -p earendil/pve-configs/lxc earendil/pve-configs/qemu
    rsync -a --delete root@earendil:/etc/pve/lxc/ earendil/pve-configs/lxc/
    rsync -a --delete root@earendil:/etc/pve/qemu-server/ earendil/pve-configs/qemu/
    # Redact any cloudinit password hashes (BSD/GNU sed compatible)
    find earendil/pve-configs -name "*.conf" -exec sed -i.bak 's|^cipassword:.*|cipassword: <REDACTED>|' {} \;
    find earendil/pve-configs -name "*.bak" -delete
    echo
    echo "✓ Snapshotted PVE configs to earendil/pve-configs/"
    echo "Review changes: git diff earendil/pve-configs/"

# --- Grafana ---

# Export every Grafana dashboard tagged 'homelab' to grafana-dashboards/.
# Strips Grafana-assigned id/version so re-saves don't churn the diff.
backup-grafana:
    #!/usr/bin/env bash
    set -euo pipefail
    GRAFANA_URL="${GRAFANA_URL:-https://grafana.vingilot.internal}"
    GRAFANA_USER="${GRAFANA_USER:-admin}"
    # Pulls from Bitwarden — vault must be unlocked (`bw unlock --raw`).
    # Item name in the personal vault: `grafana-admin`.
    GRAFANA_PASSWORD=$(bw get password grafana-admin)

    OUTDIR="grafana-dashboards"
    mkdir -p "$OUTDIR"

    # Tag filter excludes the ~30 dashboards auto-shipped by kube-prometheus-stack.
    UIDS=$(curl -fsS -u "$GRAFANA_USER:$GRAFANA_PASSWORD" \
        "$GRAFANA_URL/api/search?type=dash-db&tag=homelab" | jq -r '.[].uid')

    if [[ -z "$UIDS" ]]; then
        echo "No dashboards tagged 'homelab' found."
        exit 0
    fi

    count=0
    for uid in $UIDS; do
        curl -fsS -u "$GRAFANA_USER:$GRAFANA_PASSWORD" \
            "$GRAFANA_URL/api/dashboards/uid/$uid" | \
            jq '.dashboard | del(.id, .version)' > "$OUTDIR/${uid}.json"
        echo "  ✓ ${uid}.json"
        count=$((count + 1))
    done

    echo
    echo "Exported $count dashboard(s) to $OUTDIR/"
    echo "Review with: git diff $OUTDIR/"
