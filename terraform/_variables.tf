# PVE endpoint is non-sensitive — the URL is in the repo's docs already.
variable "pve_endpoint" {
  description = "Proxmox VE API endpoint URL (e.g. https://earendil.vingilot.internal:8006/)."
  type        = string
  default     = "https://earendil.vingilot.internal:8006/"
}

# The bpg provider reads PROXMOX_VE_API_TOKEN from the environment directly
# when `api_token` isn't set in the provider block. The justfile `tf`
# recipe decrypts ansible/group_vars/all/secrets.sops.yaml and exports it
# per-invocation, so the secret never lands in the shell's persistent env.
# No Terraform variable needed for the token.

# PBS API token secret for the `main` storage entry. PVE keeps this in
# /etc/pve/priv/storage/main.pw, separate from /etc/pve/storage.cfg, and
# bpg's storage_pbs resource requires it as a field on the resource.
# Sourced via TF_VAR_pbs_main_password from the justfile `tf` recipe.
variable "pbs_main_password" {
  description = "PBS API token secret for the `main` PBS storage entry (root@pam!earendil-host). Provide via TF_VAR_pbs_main_password env var."
  type        = string
  sensitive   = true
}
