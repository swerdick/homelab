# Partial backend config — fed to `tofu init -backend-config=backend.hcl`.
# Bucket created + hardened by bootstrap-s3-bucket.sh (one-time).
# Committed (not gitignored) because (a) solo homelab — one bucket — and
# (b) bucket name isn't sensitive; access is gated by IAM + bucket policy.

bucket = "vingilot-homelab-tfstate"
region = "us-east-2"
key    = "homelab/terraform.tfstate"
