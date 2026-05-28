# Terraform state backend. Partial configuration — bucket/region/key are
# supplied at `init` time from backend.hcl (see backend.hcl.example).
# Keeping the bucket name out of the .tf file means swapping accounts /
# rotating buckets is a one-file edit + `terraform init -reconfigure`.
#
# `use_lockfile = true` (TF 1.10+) gets us state locking via S3 conditional
# writes — no DynamoDB needed. The bucket itself must have versioning
# enabled (the bootstrap script enforces this).
#
# `encrypt = true` enables SSE on objects this backend uploads. The bucket
# also has default SSE-S3 enabled (bootstrap script), so this is
# belt-and-suspenders.

terraform {
  backend "s3" {
    encrypt      = true
    use_lockfile = true
  }
}
