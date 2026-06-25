# Terraform state backend for the Harbor stack. Partial configuration —
# bucket/region/key supplied at `init` from backend.hcl. Same S3 bucket as
# the proxmox + keycloak stacks, separate state key → independent state +
# blast radius.
#
# `use_lockfile = true` (TF 1.10+) gets state locking via S3 conditional
# writes (no DynamoDB). `encrypt = true` enables SSE on uploaded objects
# (the bucket also has default SSE-S3 from the bootstrap script).

terraform {
  backend "s3" {
    encrypt      = true
    use_lockfile = true
  }
}
