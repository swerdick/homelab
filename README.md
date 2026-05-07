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

## See also

- [`AGENTS.md`](AGENTS.md) — guidance for AI assistants working in this repo (and a useful overview for human contributors)
- [`runbooks/`](runbooks/) — written procedures for things not yet fully automated (e.g. CA rotation)
- `just --list` — recipes for common day-to-day operations
