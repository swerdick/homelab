# Terraform + provider version requirements for the Keycloak app stack.
#
# `terraform >= 1.10` for native S3 state locking (`use_lockfile` in _backend.tf),
# same as the proxmox stack. keycloak/keycloak — the official provider (migrated
# from mrparkers, maintained by the Keycloak project). Pinned to the 5.x line;
# bump deliberately.

terraform {
  required_version = ">= 1.10.0"

  required_providers {
    keycloak = {
      source  = "keycloak/keycloak"
      version = "~> 5.7"
    }
  }
}
