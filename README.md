# Homelab

Personal homelab.  A single physical machine running Proxmox, hosting a small fleet of LXCs and VMs that serve internal services for the household,
and side projects of my own development

GitOps-managed where it makes sense:

- **k3s + Flux** for cluster workloads (Grafana, Prometheus, cert-manager, Traefik via the Gateway API, etc.) under [`gondor/`](gondor/)
- **Ansible** for bare-host configuration (TLS trust store, Alloy collectors, unattended-upgrades, step-ca on tirion) under [`ansible/`](ansible/)
- **SOPS + age** for in-repo secrets

## Hosts

| name     | type        | purpose                                       |
|----------|-------------|-----------------------------------------------|
| earendil | debian host | Proxmox VE host                               |
| gondor   | debian VM   | k3s + Flux cluster                            |
| anduril  | bazzite VM  | gaming VM streaming via Moonlight             |
| tirion   | debian LXC  | step-ca (internal CA at `vingilot.internal`)  |
| nfs      | debian LXC  | NFS shares                                    |
| smb      | debian LXC  | Samba shares                                  |
| erebor   | debian LXC  | Proxmox Backup Server                         |
| aglarond | debian LXC  | restic shipping backups to Backblaze          |

## Ansible playbooks

Playbooks live under [`ansible/playbooks/`](ansible/playbooks/). Run them from the [`ansible/`](ansible/) directory so `ansible.cfg` is picked up (it enables the `community.sops.sops` vars plugin that auto-decrypts `*.sops.yaml` files):

```bash
cd ansible
ansible-playbook playbooks/<playbook>.yaml

# Dry-run with diff to preview without making changes:
ansible-playbook playbooks/<playbook>.yaml --check --diff
```

Inventory groups (`alloy`, `debian_guests`, `root_hosts`, `sudo_hosts`, etc.) are defined in [`ansible/inventory.yaml`](ansible/inventory.yaml). Some playbooks have `just` recipe wrappers (`just setup-unattended-upgrades`, `just setup-step-ca`) where it adds value; see `just --list`.

## Terraform (OpenTofu)

The Proxmox-level topology — LXC/VM definitions, bind mounts, network — is managed under [`terraform/`](terraform/) using OpenTofu + the `bpg/proxmox` provider. Phase 1 covers the five LXCs (`nfs`, `smb`, `erebor`, `aglarond`, `tirion`); VMs and the cloudinit template land in a later phase.

```sh
just tf plan      # preview against live PVE
just tf apply
```

`just tf` decrypts the PVE API token from SOPS per-invocation and runs `tofu` inside `terraform/`. State lives in the `vingilot-homelab-tfstate` S3 bucket (hardened — see `terraform/README.md`). The fresh-rebuild flow is `terraform apply` → `ansible-playbook ...` → data restore from PBS/restic.

The PVE config snapshots under [`earendil/pve-configs/`](earendil/pve-configs/) remain as a documentation + audit reference for the resources TF now owns; revisit them after a full DR drill.

## See also

- [`AGENTS.md`](AGENTS.md) — guidance for AI assistants working in this repo (and a useful overview for human contributors)
- [`runbooks/`](runbooks/) — written procedures for things not yet fully automated (e.g. CA rotation)
- [`ROADMAP.md`](ROADMAP.md) — work that's deliberately *not done yet* (future ideas, deferred upgrades, hardening)
- `just --list` — recipes for common day-to-day operations
