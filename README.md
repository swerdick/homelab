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

## Where's the Terraform?

Deliberately not used. The choice between *managing-Proxmox-from-code* and *clicking through the UI* is a real one, and this repo currently chooses the UI:

- **Proxmox UI** for guest topology — creating/destroying LXCs and VMs, assigning hardware, networking, storage. Day-to-day changes happen there.
- **Ansible** ([`ansible/`](ansible/)) for in-guest configuration — package installs, service config, TLS trust, log shipping.
- **Flux** ([`gondor/`](gondor/)) for everything inside the k3s cluster.
- **Snapshots** of PVE guest config files (committed under [`earendil/pve-configs/`](earendil/pve-configs/), produced by `just dump-pve-configs`) as a documentation + audit trail. Re-run after a UI change to capture it.

The case for Terraform is real (drift detection, reproducibility, hardware-as-code), but the cost at this scale is also real:

- A single-host fleet of ~8 guests is below the scale where Terraform's fleet-management value really pays off.
- Terraform conflicts with continuing to use the UI: every UI change creates state drift, and you have to either commit to "no more UI" or accept that your `.tf` lags reality.
- The Proxmox provider ecosystem is OK but historically rocky. `bpg/proxmox` is the actively-maintained one to use if/when the migration happens.

Revisit when: a second PVE host gets added (where fleet-management value compounds), or when UI clicks become a real pain point.

## See also

- [`AGENTS.md`](AGENTS.md) — guidance for AI assistants working in this repo (and a useful overview for human contributors)
- [`runbooks/`](runbooks/) — written procedures for things not yet fully automated (e.g. CA rotation)
- [`ROADMAP.md`](ROADMAP.md) — work that's deliberately *not done yet* (future ideas, deferred upgrades, hardening)
- `just --list` — recipes for common day-to-day operations
