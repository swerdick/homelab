# AGENTS.md

Notes for AI assistants working in this repo. Human contributors: see `README.md`.

## What this repo is

A homelab managed by `pseudo` (Stephen). Three audiences in one tree — keep all three in mind when recommending changes or taking action:

- **Real infrastructure.** Runs services pseudo actually depends on at home. Don't break things; pause before destructive operations.
- **Learning project.** The technology choices (k3s, Flux, Gateway API, cert-manager, SOPS, Ansible, Proxmox, step-ca) are partly here so pseudo can learn them. Prefer explanations that build understanding over magic incantations.
- **Resume piece.** Public on GitHub. Commit messages, structure, and naming should look professional. No `# TODO: hack` comments, no plaintext secrets, no embarrassing shortcuts.

The balance: don't propose hacky homelab shortcuts that would hurt the resume angle, and don't propose enterprise-scale complexity that doesn't fit a one-person homelab.

## Hosts

| name     | role                                          |
|----------|-----------------------------------------------|
| earendil | Proxmox VE host                               |
| gondor   | Debian VM running k3s + Flux                  |
| anduril  | Ubuntu gaming LXC (CT 117) — Steam on the shared AMD GPU |
| tirion   | LXC running step-ca (internal CA)             |
| nfs      | LXC serving NFS shares                        |
| smb      | LXC serving Samba shares                      |
| aglarond | LXC shipping restic backups to Backblaze      |
| erebor   | LXC running Proxmox Backup Server             |
| eregion  | LXC running the Fabric Minecraft server (LAN) |
| samwise  | Raspberry Pi 5 — k3s ARM worker, tailscale subnet router, WoL sender |

`earendil` shuts down nightly, taking every guest (gondor included) with it — anything consuming cluster services or metrics should tolerate that window. `anduril` no longer competes with gondor for the GPU: it shares the host's AMD card via `amdgpu` (no passthrough claim).

## Hardware

Single physical machine (earendil) hosting everything:

- **CPU**: Intel Core i7-6700K (Skylake, 4C/8T, 4.0 GHz base)
- **RAM**: 48 GB DDR4 (46.9 GiB usable), 4 DIMMs — a **mixed kit**: 2× 16 GB Corsair `CMK32GX4M2E3200C16` (rated 3200) + 2× 8 GB Corsair `CMK16GX4M2B3000C15` (rated 3000), all running at JEDEC **2133 MT/s**. **XMP: evaluated and declined.** The two kits have different rated speeds, timings, and densities, so a stable rated profile is uncertain (XMP would target the lower common denominator at best, or fail to POST), and earendil is the always-on hypervisor — RAM instability is a homelab-wide blast radius, Postgres/CNPG corruption included. The only RAM-speed-sensitive workload is CPU-bound gaming on anduril (k3s/containers are capacity/IO/CPU-bound, indifferent to DDR4 speed), and that gain is a few fps at most. Left at JEDEC 2133 deliberately — do not re-pitch XMP without this context.
- **Motherboard**: MSI Z170A Gaming M7 (MS-7976)
- **GPU**: AMD Radeon RX 9070 XT (PCI 03:00) — host-owned `amdgpu`, shared into the anduril gaming LXC (CT 117); the GTX 970 passthrough era ended June 2026. The i7-6700K's HD 530 iGPU is also present.
- **Storage**:
  - Samsung 850 EVO 250 GB SATA SSD — `rpool` (PVE root, LXC/VM disks)
  - Seagate ST2000DM005 2 TB HDD + WD WD10EZES 1 TB HDD — combined into the `bulk` and `scratch` zpools (~1.76 TB and ~900 GB usable)
- **Optical**: LG WH16NS40 16× Blu-ray writer

48 GB fits the fleet comfortably — gondor (20 GB) and the anduril CT (12 GB) are the heavyweights; the utility LXCs stay under 1 GB.

## Tooling: prefer justfile recipes

`just --list` shows the full menu. Use these instead of inventing one-liners — they encode learned-the-hard-way details (e.g. SOPS-aware validation). Most relevant for agents:

- `just validate <path>` — server-side dry-run with SOPS auto-decrypt
- `just sops-encrypt <path>` — encrypt a Secret in place via the configured age key
- `just reconcile` — force Flux to pull/apply now
- `just status` — Flux sources/kustomizations/helmreleases at a glance
- `just patch-*` — apt updates across LXCs / VM / Proxmox host
- `just check-reboots` — surface any pending reboots

If a workflow you'd repeat is missing, propose adding a recipe rather than running an ad-hoc command twice.

## Repo layout

- `kubernetes/` — k8s manifests deployed via Flux (`apps/`, `infrastructure/`)
- `ansible/` — playbooks targeting bare hosts/LXCs/VMs (community.sops vars plugin enabled)
- `<hostname>/` — host-specific scripts/notes (e.g. `earendil/`)
- `runbooks/` — written-down procedures for things not yet automated

## Secrets

- **Plaintext-only secrets** (passwords pseudo just needs to remember): **Bitwarden**.
- **In-repo secrets**: SOPS + age, configured via `.sops.yaml`.
  - `kubernetes/**/*.yaml` — encrypts only `data:` / `stringData:` (k8s Secret manifests).
  - `ansible/**/*.sops.yaml` — encrypts every value (plain Ansible vars files).
  - Encrypt with `just sops-encrypt <path>` or `sops --encrypt --in-place <path>`.
  - Edit later with `sops <path>` (opens decrypted in `$EDITOR`).
- The `community.sops.sops` Ansible vars plugin auto-decrypts `*.sops.yaml` files under `group_vars/` and `host_vars/` at playbook time.
- Never paste decrypted secrets into commits, comments, or PR descriptions.
- **Public certs are deliberately NOT encrypted** (the tirion root CA is public material, served on every TLS handshake — only private material is secret). CI's sops-guardrail enforces the boundary: every `kind: Secret` must be SOPS-encrypted; the CA travels as a plain `.crt` consumed by kustomize generators.

## DNS

Internal hostnames live under `vingilot.internal`. DNS is currently served by the upstream **Verizon CR1000A router** — there is no IaC for DNS.

**Adding a new internal hostname** (new HTTPRoute, new service) requires a manual A-record on the router *before* cert-manager can complete its HTTP-01 self-check. Most internal services point at `192.168.1.220`.

PiHole / AdGuard is on the roadmap; update this section when that lands.

## TLS

Internal CA: **step-ca on `tirion`**. cert-manager `ClusterIssuer` named `tirion` issues per-service certs via HTTP-01 over the `vingilot` Gateway. The root CA is already trusted on every homelab host.

**Do not run `ansible/playbooks/distribute-root-ca.yaml` reflexively** — it has cascading effects (Proxmox fingerprint pinning, etc.). Only run during an actual root rotation.

## Conventions

- File extension: **`.yaml`**, not `.yml`. Stay consistent.
- Commit style: conventional-ish (`feat:`, `fix:`, `chore(scope):`, `refactor:`, `test:`). Match the tone in `git log`.
- **Always pause for human review before `git commit` or `git push`**, even when prior approval to "commit as we go" was given. The user wants to inspect staged changes first.
- **Ansible playbooks must be safely runnable unrestricted.** `-l <host>` is a development convenience, not a safety mechanism — a future edit could forget it. After any template/var/task change, preview with `ansible-playbook --check --diff playbooks/<name>.yaml` (no `-l`) and inspect the PLAY RECAP: every host that isn't the intended target must show `changed=0`. Drift caught: a Jinja conditional with stray surrounding whitespace once made `config.alloy` render with a one-line diff on every host, which would have triggered a fleet-wide alloy restart cascade. Move blank lines *inside* the conditional, gate task-level work with `when:`, and verify before applying.
- Cluster changes flow through Flux — don't `kubectl apply` directly to gondor for things that should be in `kubernetes/`. Edit the manifest, commit, push, `just reconcile`.
- **When deploying a new service to gondor (or anywhere else), search for current installation documentation online before drafting manifests.** Don't rely on memory for chart versions, values structure, deployment modes, or required fields — they drift fast (the Loki chart jumped from 6.x to 13.x in months, with breaking values changes; landing on a stale constraint silently rendered an empty install before we caught it). Fetch the project's official install docs *and* the chart's current `values.yaml` from `main` (or the specific tagged release) before writing the HelmRelease.
- **Tag every Grafana dashboard you build with `homelab`.** The `just backup-grafana` recipe filters `?tag=homelab` to skip the ~30 dashboards auto-shipped by kube-prometheus-stack — anything you create without that tag won't be backed up to git, and won't survive a Grafana DB wipe.
- **New OIDC apps map permissions to the two existing Keycloak groups, never to per-app local users.** `homelab-admins` → that app's full-admin role (Grafana `GrafanaAdmin`, Harbor `sysadmin_flag`, Immich Admin, etc.); `homelab-readonly` → its read-only role (Viewer / Limited Guest / equivalent). Membership stays hand-managed in the Keycloak UI — humans-in-UI, structure-in-TF — so adding a new person to all apps at the right tier is a one-click group-add. Wire a `keycloak_openid_group_membership_protocol_mapper` on the new client in `terraform/keycloak/keycloak.tf` (pattern: `<app>_groups`, `claim_name: groups`, `full_path: false`); without it the token carries no group info and the app sees nothing to map. Per-app *consumption* differs (Grafana JMESPath, Harbor UI fields, Immich claim mapping) — see Worked examples. Don't pre-create a local user matching your Keycloak username; let OAuth onboarding create it (login-collision blocks first sign-up with a misleading "user not found").

## Worked examples (read these before adding similar things)

- **New internal HTTPS service**: `kubernetes/apps/observability/grafana-route.yaml` + the `grafana-https` listener in `kubernetes/infrastructure/instances/traefik/gateway.yaml`. Pattern is: Gateway listener with hostname, cert-manager Certificate, HTTPRoute, optional traefik Middleware via `ExtensionRef` filter. Plus a router DNS record.
- **Encrypted credentials with both k8s + Ansible sides**: `prometheus-basic-auth` (k8s, bcrypt) paired with `ansible/group_vars/alloy/secrets.sops.yaml` (plaintext). Rotating means updating both files in lockstep.
- **New OIDC app integration**: read the three existing wirings as a set. (1) `terraform/keycloak/keycloak.tf` — `keycloak_openid_client.<app>` + sensitive `<app>_oidc_client_secret` output + `<app>_groups` membership mapper. (2) Per-pod CA mount so the pod trusts `keycloak.vingilot.internal` (chart-native `caBundleSecretName` for Harbor; ConfigMap + `NODE_EXTRA_CA_CERTS` for Immich/Node; ConfigMap + `auth.generic_oauth.tls_client_ca` for Grafana/Go — OAuth-scoped, system trust untouched). (3) Role mapping: Grafana's `role_attribute_path` JMESPath in `kubernetes/apps/observability/kube-prometheus-stack.yaml`; Harbor's `oidc_admin_group` + `oidc_groups_claim` + `oidc_user_claim: preferred_username` saved via UI or PUT to `/api/v2.0/configurations`; Immich is a manual UI bump until we add a Keycloak Script Mapper or per-user attribute. Local admins (`*-admin.yaml` SOPS Secrets) stay as break-glass only.
