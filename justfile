# Lockstep with kubernetes/bootstrap/install-k3s.sh and
# ansible/host_vars/samwise/main.yaml — bump all three together until the
# "refactor install-k3s.sh to ansible" ROADMAP item collapses them.
k3s_version := "v1.34.6+k3s1"

# All Debian-based LXCs on earendil
debian_lxcs := "120 121 130 131 141 142"

# List all available recipes
default:
    @just --list

# --- Bootstrap ---

bootstrap-gondor:
    ssh gondor 'K3S_VERSION={{k3s_version}} bash -s' < kubernetes/bootstrap/install-k3s.sh

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
    bash kubernetes/bootstrap/bootstrap-flux.sh

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
# (currently: data: and stringData: under any kubernetes/*.yaml).
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

# Patch everything apt-based except the gaming CT: Proxmox host, all Debian
# LXCs, gondor VM. anduril (CT 117) is deliberately separate — see patch-anduril.
patch-all: patch-earendil patch-lxcs patch-gondor
    @echo
    @echo "All always-on apt hosts patched."
    @echo "Reminder: run 'just patch-anduril' separately (kept out so a live gaming session never gets yanked)."

# Patch the anduril gaming LXC (CT 117 — always-on, shares the host kernel).
# Security updates land unattended; this is the deliberate full `apt upgrade`.
# LXC = no kernel or NVIDIA stack inside (the VM-era holds are gone), so
# autoremove is safe here. Kept out of patch-all so a live gaming session
# never gets yanked mid-play — run between sessions.
patch-anduril:
    @echo "Patching anduril (gaming CT)..."
    ssh anduril 'sudo bash -c "export DEBIAN_FRONTEND=noninteractive && apt update && apt -y upgrade && apt -y autoremove && apt clean"'

# Cleanly restart the anduril gaming session (KWin + Steam Big Picture) in CT 117.
# Use this instead of Steam's in-app "Restart"/"Shut Down" power menu: the
# container can't honor a logind reboot, so that menu just blanks the TV with a
# dead session. Stops the session, kills any stray Steam (e.g. an instance left
# running in an xrdp desktop session — Steam is single-instance per user, so a
# leftover would make the TV's `steam -gamepadui` signal it instead of painting
# the TV), then starts fresh.
restart-anduril:
    @echo "Restarting the anduril gaming session..."
    ssh root@earendil 'pct exec 117 -- bash -c "systemctl stop anduril-session.service; sleep 2; systemctl reset-failed anduril-session.service; systemctl start anduril-session.service"'

# `just stop-steam` aliases this — stop the TV Steam for desktop/SRM/emulator work.
alias stop-steam := anduril-desktop-mode

# Drop anduril into desktop-admin mode: stop the TV gaming session so Steam is
# free for an xrdp desktop session (Steam is single-instance per user). RDP to
# the CT as `pseudo` for desktop Steam / Prism / emulator config, then run
# `just restart-anduril` to return to Big Picture on the TV.
anduril-desktop-mode:
    @echo "Stopping the TV session — RDP to 192.168.1.17 as pseudo for desktop admin."
    @echo "Run 'just restart-anduril' when done to return to the TV."
    ssh root@earendil 'pct exec 117 -- systemctl stop anduril-session.service'

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

# Three independent stacks, each with its own state, backend key, and providers:
#   terraform/proxmox/  — PVE host + guests + storage + backup jobs (bpg/proxmox)
#   terraform/keycloak/ — Keycloak realm/client config (keycloak/keycloak)
#   terraform/harbor/   — Harbor proxy-cache projects/registries (goharbor/harbor)
#
# Each recipe decrypts only the secrets ITS stack needs from SOPS and exports
# them per-invocation, then runs `tofu` from that stack's dir. Splitting the
# secrets per stack means a proxmox change never depends on the Keycloak secret
# (and vice versa). Secrets live in the process env only for the tofu invocation;
# `sops --extract` avoids YAML-parsing fragility.
#
#   just tf-proxmox plan
#   just tf-proxmox import proxmox_virtual_environment_container.aglarond earendil/131
#   just tf-keycloak plan   /   just tf-keycloak apply
# Re-init after a backend/provider change: just tf-proxmox-init / just tf-keycloak-init

# Proxmox infra stack — PROXMOX_VE_API_TOKEN (bpg's native env var) +
# TF_VAR_pbs_main_password (the `main` PBS storage token).
tf-proxmox +args:
    @cd terraform/proxmox && \
      PROXMOX_VE_API_TOKEN="$(sops --decrypt --extract '["pve_api_token"]' ../../ansible/group_vars/all/secrets.sops.yaml)" \
      TF_VAR_pbs_main_password="$(sops --decrypt --extract '["pbs_main_password"]' ../../ansible/group_vars/all/secrets.sops.yaml)" \
      tofu {{args}}

tf-proxmox-init:
    cd terraform/proxmox && tofu init -backend-config=backend.hcl

# Keycloak app stack — KEYCLOAK_CLIENT_SECRET for the `terraform` service-account
# client (client-credentials grant). Add it under key
# `keycloak_terraform_client_secret` via `sops ansible/group_vars/all/secrets.sops.yaml`.
tf-keycloak +args:
    @cd terraform/keycloak && \
      KEYCLOAK_CLIENT_SECRET="$(sops --decrypt --extract '["keycloak_terraform_client_secret"]' ../../ansible/group_vars/all/secrets.sops.yaml)" \
      tofu {{args}}

tf-keycloak-init:
    cd terraform/keycloak && tofu init -backend-config=backend.hcl

# Harbor app stack — HARBOR_PASSWORD for the local `admin` user. Sourced from
# the cluster Secret SOPS file (single source of truth: kubernetes/apps/harbor/
# harbor-admin.yaml) rather than a duplicate copy in secrets.sops.yaml. If the
# admin password ever drifts (live rotated, SOPS not updated — see
# [[project_harbor_admin_seed_only]]), this recipe will fail loud at TF auth
# time, which is the right signal to re-sync SOPS.
tf-harbor +args:
    @cd terraform/harbor && \
      HARBOR_USERNAME=admin \
      HARBOR_PASSWORD="$(sops --decrypt --extract '["stringData"]["HARBOR_ADMIN_PASSWORD"]' ../../kubernetes/apps/harbor/harbor-admin.yaml)" \
      tofu {{args}}

tf-harbor-init:
    cd terraform/harbor && tofu init -backend-config=backend.hcl

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
