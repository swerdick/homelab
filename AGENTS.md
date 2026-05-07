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
| anduril  | Bazzite gaming VM (GPU passthrough)           |
| tirion   | LXC running step-ca (internal CA)             |
| nfs      | LXC serving NFS shares                        |
| smb      | LXC serving Samba shares                      |
| aglarond | LXC shipping restic backups to Backblaze      |
| erebor   | LXC running Proxmox Backup Server             |

`gondor` and `anduril` share GPU resources — gondor is shut down sometimes so anduril can run. Components that depend on the cluster (Prometheus, Grafana, anything in `gondor/`) should tolerate gondor being unavailable.

## Hardware

Single physical machine (earendil) hosting everything:

- **CPU**: Intel Core i7-6700K (Skylake, 4C/8T, 4.0 GHz base)
- **RAM**: 16 GB DDR4 — Corsair Vengeance LPX CMK16GX4M2B3000C15 (kit is rated 3000 MHz; running at JEDEC 2133 because no XMP profile is enabled). **TODO**: enable XMP in BIOS during a planned maintenance window for ~40% more memory bandwidth. Requires a full earendil reboot (homelab-wide outage) and a memtest86 pass to confirm Skylake's IMC stays stable at the rated profile.
- **Motherboard**: MSI Z170A Gaming M7 (MS-7976)
- **GPU**: Nvidia GeForce GTX 970 — passed through to anduril for Moonlight game streaming
- **Storage**:
  - Samsung 850 EVO 250 GB SATA SSD — `rpool` (PVE root, LXC/VM disks)
  - Seagate ST2000DM005 2 TB HDD + WD WD10EZES 1 TB HDD — combined into the `bulk` and `scratch` zpools (~1.76 TB and ~900 GB usable)
- **Optical**: LG WH16NS40 16× Blu-ray writer

16 GB is tight for the size of the fleet — VM sizing matters: gondor at 10 GB is the heaviest, others kept under 1 GB where possible.

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

- `gondor/` — k8s manifests deployed via Flux (`apps/`, `infrastructure/`)
- `ansible/` — playbooks targeting bare hosts/LXCs/VMs (community.sops vars plugin enabled)
- `<hostname>/` — host-specific scripts/notes (e.g. `earendil/`, `tirion/`)
- `runbooks/` — written-down procedures for things not yet automated
- `utility/` — one-off scripts (e.g. `distribute-root-ca.sh`)

## Secrets

- **Plaintext-only secrets** (passwords pseudo just needs to remember): **Bitwarden**.
- **In-repo secrets**: SOPS + age, configured via `.sops.yaml`.
  - `gondor/**/*.yaml` — encrypts only `data:` / `stringData:` (k8s Secret manifests).
  - `ansible/**/*.sops.yaml` — encrypts every value (plain Ansible vars files).
  - Encrypt with `just sops-encrypt <path>` or `sops --encrypt --in-place <path>`.
  - Edit later with `sops <path>` (opens decrypted in `$EDITOR`).
- The `community.sops.sops` Ansible vars plugin auto-decrypts `*.sops.yaml` files under `group_vars/` and `host_vars/` at playbook time.
- Never paste decrypted secrets into commits, comments, or PR descriptions.

## DNS

Internal hostnames live under `vingilot.internal`. DNS is currently served by the upstream **Verizon CR1000A router** — there is no IaC for DNS.

**Adding a new internal hostname** (new HTTPRoute, new service) requires a manual A-record on the router *before* cert-manager can complete its HTTP-01 self-check. Most internal services point at `192.168.1.220`.

PiHole / AdGuard is on the roadmap; update this section when that lands.

## TLS

Internal CA: **step-ca on `tirion`**. cert-manager `ClusterIssuer` named `tirion` issues per-service certs via HTTP-01 over the `vingilot` Gateway. The root CA is already trusted on every homelab host.

**Do not run `utility/distribute-root-ca.sh` reflexively** — it has cascading effects (Proxmox fingerprint pinning, etc.). Only run during an actual root rotation.

## Conventions

- File extension: **`.yaml`**, not `.yml`. Stay consistent.
- Commit style: conventional-ish (`feat:`, `fix:`, `chore(scope):`, `refactor:`, `test:`). Match the tone in `git log`.
- **Always pause for human review before `git commit` or `git push`**, even when prior approval to "commit as we go" was given. The user wants to inspect staged changes first.
- Cluster changes flow through Flux — don't `kubectl apply` directly to gondor for things that should be in `gondor/`. Edit the manifest, commit, push, `just reconcile`.

## Worked examples (read these before adding similar things)

- **New internal HTTPS service**: `gondor/apps/observability/grafana-route.yaml` + the `grafana-https` listener in `gondor/infrastructure/instances/traefik/gateway.yaml`. Pattern is: Gateway listener with hostname, cert-manager Certificate, HTTPRoute, optional traefik Middleware via `ExtensionRef` filter. Plus a router DNS record.
- **Encrypted credentials with both k8s + Ansible sides**: `prometheus-basic-auth` (k8s, bcrypt) paired with `ansible/group_vars/alloy/secrets.sops.yaml` (plaintext). Rotating means updating both files in lockstep.
