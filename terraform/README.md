# Terraform (OpenTofu)

Manages the Proxmox-level topology — LXC and VM definitions — on `earendil`. Pairs with `ansible/` for in-guest config and `gondor/` for cluster workloads.

Currently in scope (Phase 1): the five LXCs (`nfs`, `smb`, `erebor`, `aglarond`, `tirion`). Deferred to later phases: `gondor`/`anduril` VMs, the Debian cloudinit template, and datacenter-level config (backup jobs, storage registration).

## Day-to-day

```sh
just tf plan      # preview changes against live PVE
just tf apply     # apply
just tf state list
```

`just tf` is a thin wrapper that decrypts the PVE API token from SOPS, exports it as `PROXMOX_VE_API_TOKEN` (bpg provider's native env var), and runs `tofu` inside `terraform/`. The token never lands in the parent shell's env.

## Adding a new resource via import

Workflow for backporting something that already exists in PVE:

1. Add an import block to `_imports.tf`:
   ```hcl
   import {
     to = proxmox_virtual_environment_container.foo
     id = "earendil/<vmid>"
   }
   ```
2. `just tf plan -generate-config-out=generated.tf` → bpg emits a verbose HCL block for the live state.
3. Clean it up into its own `foo.tf` file. Known cleanups bpg's generator gets wrong:
   - Drop `cpu.units = 0` and `cpu.limit = 0` (validation rejects 0)
   - Drop `initialization.entrypoint = ""` (invalid chars)
   - Drop `initialization.dns.servers = []` (empty list rejected; keep `dns.domain`)
   - Drop `initialization.ip_config.ipv4.gateway = ""` if DHCP
   - Keep `operating_system.template_file_id = ""` (schema requires it)
4. Add a `lifecycle { ignore_changes = [...] }` block for the timeout attrs (see Quirks).
5. For LXCs with operator runbook descriptions, save the live description to `descriptions/<name>.md` and load via `description = file("${path.module}/descriptions/<name>.md")`.
6. Delete `generated.tf`, clear the import block from `_imports.tf`.
7. `just tf plan` must be a clean no-op. Then `just tf apply` commits the import to state.

## Disaster recovery (fresh PVE rebuild)

1. **Hardware** + Proxmox install on `earendil`. Create ZFS pools: `rpool` (PVE installer) + `zpool create bulk ...` + `zpool create scratch ...` per the host's hardware notes.
2. **PVE access for Terraform** — restore `/etc/pve` from PBS *or* re-run:
   ```sh
   cd ansible
   ansible-playbook playbooks/setup-terraform-pve-access.yaml
   ```
   The playbook recreates the user/role/ACL and prints the one-time `pveum user token add` command for the operator to run + capture into SOPS.
3. **S3 state bucket** — already exists in your AWS account, no action needed unless it was deleted. If recreating, run `terraform/scripts/bootstrap-s3-bucket.sh` (idempotent, applies full hardening).
4. **Terraform** —
   ```sh
   just tf-init       # one-time per checkout
   just tf apply      # recreates the 5 LXCs on bare PVE
   ```
5. **Ansible** — run the bootstrap chain in order: `setup-pseudo-user` → `setup-debian-base` → `distribute-root-ca` → `install-alloy` → per-host plays (`install-step-ca` on tirion, `manage-nfs-exports` on nfs, etc.).
6. **Restore data** — PBS for guest snapshots, restic on aglarond for `/etc` + `/bulk/*`.

## S3 state bucket hardening (non-negotiable)

The `vingilot-homelab-tfstate` bucket in `us-east-2` is set up by `scripts/bootstrap-s3-bucket.sh`. Every flag below is mandatory and the script enforces them idempotently:

- **Public Access Block** — all four flags (`BlockPublicAcls`, `IgnorePublicAcls`, `BlockPublicPolicy`, `RestrictPublicBuckets`) set to true.
- **Bucket policy** — explicit `Deny` on any request where `aws:SecureTransport != true` (forces TLS).
- **Versioning** — enabled. tfstate corruption / accidental delete is recoverable.
- **Encryption** — SSE-S3 default with bucket-key enabled.
- **IAM** — accessed via the operator's existing `pseudo` IAM user (broad). Tighten to a dedicated scoped IAM policy when the homelab outgrows single-operator scale.

Verify any time with:
```sh
aws s3api get-public-access-block --bucket vingilot-homelab-tfstate
aws s3api get-bucket-policy --bucket vingilot-homelab-tfstate --query Policy --output text | jq .
aws s3api get-bucket-versioning --bucket vingilot-homelab-tfstate
aws s3api get-bucket-encryption --bucket vingilot-homelab-tfstate
```

## Quirks

- **bpg's import populates `timeout_*` state from null → defaults**, which surfaces as a diff and (worse) trips an HTTP 500 from PVE on apply because bpg PUTs an empty body. Every resource here has a `lifecycle { ignore_changes = [timeout_clone, timeout_create, timeout_delete, timeout_start, timeout_update] }` block as a result. These are TF-side wait knobs, never stored on PVE — safe to ignore.
- **Don't set `vm_id` in config alongside an import block.** Setting it doesn't suppress the state-fill diff and adds noise. Let it derive from the import ID (`earendil/131`).
- **`operating_system.template_file_id = ""`** is schema-required even though it only matters at initial container creation. Imported containers leave it as empty string.
- **smb's idmap** — bpg requires SSH for *modifying* `lxc.idmap` lines (the API doesn't accept `lxc[n]` parameters). Reading on import works fine over the API; if we ever need to change smb's idmap via TF, the provider block needs an `ssh {}` block added.

## Files

- `_versions.tf`, `_providers.tf`, `_backend.tf`, `_variables.tf` + `backend.hcl` — module scaffolding (provider/version pins, backend config). Underscore prefix groups them visually at the top of `ls`.
- `_imports.tf` — staging area for in-flight imports; empty when no work in progress.
- `aglarond.tf`, `erebor.tf`, `nfs.tf`, `smb.tf`, `tirion.tf` — one resource per LXC.
- `descriptions/` — sidecar markdown for LXCs whose PVE "Notes" tab carries an operator runbook.
- `scripts/bootstrap-s3-bucket.sh` — one-time bucket creation + hardening (idempotent). Non-`.tf` files in subdirs are ignored by OpenTofu, so this lives outside the module graph.
- `.terraform.lock.hcl` — provider version pins; **committed for reproducibility** (not gitignored).
