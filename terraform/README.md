# Terraform (OpenTofu)

Two independent stacks — each with its own state, backend key, and provider, run separately:

| Stack | Path | Manages | Provider | State key |
|---|---|---|---|---|
| **proxmox** | `terraform/proxmox/` | PVE topology on `earendil` — guests, storage, backup jobs, datacenter options | `bpg/proxmox` | `homelab/terraform.tfstate` |
| **keycloak** | `terraform/keycloak/` | Keycloak realm/client config — OIDC clients for in-cluster apps | `keycloak/keycloak` | `homelab/keycloak.tfstate` |

Both use the same S3 bucket (`vingilot-homelab-tfstate`, `us-east-2`) with separate keys, so state and blast radius are isolated. Splitting also means each stack only loads and authenticates *its own* provider — a proxmox change never needs the Keycloak secret, and vice versa. Pairs with `ansible/` (in-guest + host config) and `gondor/` (cluster workloads).

## Day-to-day

```sh
# Proxmox infra
just tf-proxmox plan
just tf-proxmox apply
just tf-proxmox state list

# Keycloak config
just tf-keycloak plan
just tf-keycloak apply
just tf-keycloak output -raw immich_oidc_client_secret

# Re-init a stack after a backend/provider change (one-time per checkout):
just tf-proxmox-init   /   just tf-keycloak-init
```

Each `just tf-<stack>` recipe decrypts only that stack's secrets from SOPS and exports them for the single `tofu` invocation (proxmox: `PROXMOX_VE_API_TOKEN` + `TF_VAR_pbs_main_password`; keycloak: `KEYCLOAK_CLIENT_SECRET`). Secrets never land in the parent shell's persistent env.

---

## proxmox stack

In scope: the LXCs (`nfs`, `smb`, `erebor`, `aglarond`, `tirion`, `eregion`), the `gondor` k3s VM, the `anduril` VM (GPU passthrough); storage (`backups` local vzdump dir, `main` PBS on erebor, `scratch-zfs`); the four backup jobs; datacenter options (`keyboard`, `mac_prefix`). Out of scope: `local`/`local-zfs` (auto-created by the PVE installer), the discarded Debian cloudinit template, network bridges (`vmbr0`).

### Adding a resource via import

1. Add an import block to `_imports.tf`:
   ```hcl
   import {
     to = proxmox_virtual_environment_container.foo
     id = "earendil/<vmid>"
   }
   ```
2. `just tf-proxmox plan -generate-config-out=generated.tf` → bpg emits verbose HCL for the live state.
3. Clean it into its own `foo.tf`. Known cleanups bpg's generator gets wrong:
   - Drop `cpu.units = 0` and `cpu.limit = 0` (validation rejects 0)
   - Drop `initialization.entrypoint = ""` (invalid chars)
   - Drop `initialization.dns.servers = []` (empty list rejected; keep `dns.domain`)
   - Drop `initialization.ip_config.ipv4.gateway = ""` if DHCP
   - Keep `operating_system.template_file_id = ""` (schema requires it)
4. Add a `lifecycle { ignore_changes = [...] }` block for the timeout attrs (see Quirks).
5. For LXCs with operator runbook descriptions, save the live description to `descriptions/<name>.md` and load via `description = file("${path.module}/descriptions/<name>.md")`.
6. Delete `generated.tf`, clear the import block from `_imports.tf`.
7. `just tf-proxmox plan` must be a clean no-op. Then `just tf-proxmox apply` commits the import to state.

### Quirks

- **bpg's import populates `timeout_*` state from null → defaults**, which surfaces as a diff and (worse) trips an HTTP 500 from PVE on apply because bpg PUTs an empty body. Every resource here has a `lifecycle { ignore_changes = [timeout_clone, timeout_create, timeout_delete, timeout_start, timeout_update] }` block as a result. These are TF-side wait knobs, never stored on PVE — safe to ignore.
- **Don't set `vm_id` in config alongside an import block.** Setting it doesn't suppress the state-fill diff and adds noise. Let it derive from the import ID (`earendil/131`).
- **`operating_system.template_file_id = ""`** is schema-required even though it only matters at initial container creation. Imported containers leave it as empty string.
- **smb's idmap** — bpg requires SSH for *modifying* `lxc.idmap` lines (the API doesn't accept `lxc[n]` parameters). Reading on import works fine over the API; if we ever need to change smb's idmap via TF, the provider block needs an `ssh {}` block added.

## keycloak stack

Manages Keycloak realm config as code. Currently: the **Immich** OIDC client in the `vingilot` realm. The realm itself is hand-created (not TF-managed) — clients reference it by `realm_id = "vingilot"`, which avoids churning a `keycloak_realm` resource's many settings. New app clients are a ~15-line `keycloak_openid_client` block in `keycloak.tf` + `just tf-keycloak apply`.

**Provider auth** is the client-credentials grant via a dedicated `terraform` service-account client in Keycloak's **master** realm — created once in the UI, granted the master `admin` role, with its secret stored in SOPS under `keycloak_terraform_client_secret`. Because the provider authenticates on every invocation, that secret must be present or `just tf-keycloak` fails at provider auth.

---

## S3 state bucket hardening (non-negotiable)

The `vingilot-homelab-tfstate` bucket in `us-east-2` is set up by `scripts/bootstrap-s3-bucket.sh` (shared by both stacks). Every flag below is mandatory and the script enforces them idempotently:

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

## Disaster recovery (fresh PVE rebuild)

1. **Hardware** + Proxmox install on `earendil`. Create ZFS pools: `rpool` (PVE installer) + `zpool create bulk ...` + `zpool create scratch ...` per the host's hardware notes.
2. **PVE access for Terraform** — restore `/etc/pve` from PBS *or* re-run `ansible-playbook playbooks/setup-terraform-pve-access.yaml` (recreates the user/role/ACL + prints the one-time `pveum user token add` to capture into SOPS).
3. **S3 state bucket** — already exists; if recreating, run `terraform/scripts/bootstrap-s3-bucket.sh` (idempotent, full hardening).
4. **Terraform** — `just tf-proxmox-init` then `just tf-proxmox apply` recreates the LXCs/VMs on bare PVE. (Keycloak: `just tf-keycloak-init` + `apply` once Keycloak is back up.)
5. **Ansible** — bootstrap chain in order: `setup-pseudo-user` → `setup-debian-base` → `distribute-root-ca` → `install-alloy` → per-host plays.
6. **Restore data** — PBS for guest snapshots, restic on aglarond for `/etc` + `/bulk/*`.

## Files

- `proxmox/` — the PVE infra stack: `_versions/_providers/_variables/_backend.tf` + `backend.hcl` scaffolding, one `*.tf` per guest, `_imports.tf` (staging for in-flight imports; empty when idle), `descriptions/` (sidecar markdown for PVE "Notes" runbooks).
- `keycloak/` — the Keycloak stack: same scaffolding + `keycloak.tf` (the app clients).
- `scripts/bootstrap-s3-bucket.sh` — one-time bucket creation + hardening (idempotent), shared by both stacks.
- each stack's `.terraform.lock.hcl` — provider version pins; **committed for reproducibility** (not gitignored).
