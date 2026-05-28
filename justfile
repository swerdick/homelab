# Lockstep with gondor/bootstrap/install-k3s.sh and
# ansible/host_vars/samwise/main.yaml — bump all three together until the
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

# Patch everything always-on that takes apt: Proxmox host, all LXCs, gondor VM.
# anduril (Kubuntu gaming VM) is off most of the time and patched on demand.
patch-all: patch-earendil patch-lxcs patch-gondor
    @echo
    @echo "All always-on apt hosts patched."
    @echo "Reminder: anduril is off most of the time — run 'just patch-anduril' while it's running (stop eregion first)."

# Patch the Kubuntu gaming VM (anduril) — only works while the VM is running.
# anduril is off most of the time and shares earendil's RAM with eregion until
# the RAM upgrade, so stop eregion (pct stop 142) before booting it.
#
# Security updates already land unattended; this is the deliberate full
# `apt upgrade`. NVIDIA is `apt-mark hold`ed (so 595 — which drops the GTX
# 970's Maxwell arch — can never be pulled) and Sunshine isn't in any apt
# repo, so neither moves here. The kernel is only held from *unattended*
# upgrades (host_vars/anduril), so this WILL bump it — take a fresh PBS
# snapshot first if a passthrough-breaking kernel regression would hurt, and
# reboot deliberately afterward (GPU cold-start is the reliability bar).
patch-anduril:
    @echo "Patching anduril (Kubuntu)..."
    ssh anduril 'sudo bash -c "export DEBIAN_FRONTEND=noninteractive && apt update && apt -y upgrade && apt -y autoremove && apt clean"'

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

# --- OpenTofu / Terraform ---

# Wrapper that decrypts the secrets needed by Terraform from SOPS, exports
# them as env vars per-invocation, and runs `tofu` from terraform/ so
# backend.hcl + .tf files resolve.
#
#   just tf plan
#   just tf apply
#   just tf import proxmox_virtual_environment_container.aglarond earendil/131
#
# Three secrets exported:
#   - PROXMOX_VE_API_TOKEN: bpg provider's native env var (used by the
#     provider block to talk to PVE).
#   - TF_VAR_pbs_main_password: the API token secret for the `main` PBS
#     storage entry. PVE keeps this in /etc/pve/priv/storage/main.pw,
#     separate from /etc/pve/storage.cfg, and bpg's storage_pbs resource
#     requires it.
#   - KEYCLOAK_CLIENT_SECRET: secret for the `terraform` service-account
#     client in Keycloak's master realm (client-credentials grant for the
#     keycloak provider). Add it under key `keycloak_terraform_client_secret`
#     via `sops ansible/group_vars/all/secrets.sops.yaml`. NOTE: once the
#     keycloak provider exists, every `just tf` configures it — so this secret
#     must be present or all tofu commands fail at provider auth.
#
# Secrets live in the parent shell's process env only for the duration of
# the tofu invocation; sops --extract avoids YAML parsing fragility.
tf +args:
    @cd terraform && \
      PROXMOX_VE_API_TOKEN="$(sops --decrypt --extract '["pve_api_token"]' ../ansible/group_vars/all/secrets.sops.yaml)" \
      TF_VAR_pbs_main_password="$(sops --decrypt --extract '["pbs_main_password"]' ../ansible/group_vars/all/secrets.sops.yaml)" \
      KEYCLOAK_CLIENT_SECRET="$(sops --decrypt --extract '["keycloak_terraform_client_secret"]' ../ansible/group_vars/all/secrets.sops.yaml)" \
      tofu {{args}}

# One-shot init with the partial backend config. Re-run with -reconfigure
# if backend.hcl ever changes.
tf-init:
    cd terraform && tofu init -backend-config=backend.hcl

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
