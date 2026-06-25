# Terraform + provider version requirements for the Harbor app stack.
#
# `terraform >= 1.10` for native S3 state locking (`use_lockfile` in _backend.tf),
# same as the proxmox + keycloak stacks. goharbor/harbor — the official provider
# maintained by the Harbor project. Pinned to the 3.x line.

terraform {
  required_version = ">= 1.10.0"

  required_providers {
    harbor = {
      source  = "goharbor/harbor"
      version = "~> 3.11"
    }
  }
}
