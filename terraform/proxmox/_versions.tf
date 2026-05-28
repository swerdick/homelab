# Terraform + provider version requirements for the Proxmox infra stack.
#
# `terraform >= 1.10` is required for native S3 state locking via
# `use_lockfile = true` in _backend.tf. Pre-1.10 would force us into the
# DynamoDB-table dance, which is extra cost + a second resource to manage.
# Upgrade via `brew upgrade terraform` (or switch to OpenTofu; the syntax
# here is compatible with both).
#
# `bpg/proxmox` is pinned at the latest minor at time of writing. Bump
# deliberately — provider changes between minors have caused breaking
# behavior in past releases (see bpg's CHANGELOG before upgrading).

terraform {
  required_version = ">= 1.10.0"

  required_providers {
    proxmox = {
      source  = "bpg/proxmox"
      version = "~> 0.106"
    }
  }
}
