#!/usr/bin/env bash
# Bootstrap the S3 bucket used as the Terraform state backend.
#
# Idempotent: safe to re-run. Applies the full hardening checklist:
#   - Block all public access (4 flags)
#   - Bucket policy denying any non-TLS access
#   - Versioning enabled
#   - Default SSE-S3 encryption
#
# Does NOT create the IAM user/policy that scopes access — the operator
# uses their existing AWS credentials (pseudo IAM user). Tighten with a
# dedicated IAM policy when the homelab outgrows single-operator scale.
#
# Usage:
#     BUCKET=homelab-tfstate REGION=us-east-2 ./bootstrap-s3-bucket.sh
#
# Env defaults match this homelab's setup. Override BUCKET if the default
# name is taken globally (S3 bucket names are global).

set -euo pipefail

BUCKET="${BUCKET:-vingilot-homelab-tfstate}"
REGION="${REGION:-us-east-2}"

echo ">>> bootstrap-s3-bucket.sh"
echo "    bucket: $BUCKET"
echo "    region: $REGION"
echo

# --- 1. Create bucket (idempotent) ---
if aws s3api head-bucket --bucket "$BUCKET" 2>/dev/null; then
    echo "[1/5] bucket already exists, skipping create"
else
    echo "[1/5] creating bucket"
    # us-east-1 is the magic region that does NOT accept a LocationConstraint.
    # Every other region requires one. Handle both.
    if [ "$REGION" = "us-east-1" ]; then
        aws s3api create-bucket --bucket "$BUCKET" --region "$REGION" >/dev/null
    else
        aws s3api create-bucket \
            --bucket "$BUCKET" \
            --region "$REGION" \
            --create-bucket-configuration "LocationConstraint=$REGION" >/dev/null
    fi
fi

# --- 2. Block all public access ---
echo "[2/5] applying public access block (all four flags)"
aws s3api put-public-access-block \
    --bucket "$BUCKET" \
    --public-access-block-configuration \
    "BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true"

# --- 3. Bucket policy: deny any non-TLS request ---
echo "[3/5] applying deny-non-TLS bucket policy"
POLICY=$(cat <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "DenyNonSecureTransport",
      "Effect": "Deny",
      "Principal": "*",
      "Action": "s3:*",
      "Resource": [
        "arn:aws:s3:::$BUCKET",
        "arn:aws:s3:::$BUCKET/*"
      ],
      "Condition": {
        "Bool": {
          "aws:SecureTransport": "false"
        }
      }
    }
  ]
}
EOF
)
aws s3api put-bucket-policy --bucket "$BUCKET" --policy "$POLICY"

# --- 4. Versioning ---
echo "[4/5] enabling versioning"
aws s3api put-bucket-versioning \
    --bucket "$BUCKET" \
    --versioning-configuration Status=Enabled

# --- 5. Default server-side encryption (SSE-S3) ---
echo "[5/5] enabling default SSE-S3 encryption"
aws s3api put-bucket-encryption \
    --bucket "$BUCKET" \
    --server-side-encryption-configuration \
    '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"},"BucketKeyEnabled":true}]}'

echo
echo ">>> done. Verify with:"
echo "    aws s3api get-public-access-block --bucket $BUCKET"
echo "    aws s3api get-bucket-policy --bucket $BUCKET --query Policy --output text | jq ."
echo "    aws s3api get-bucket-versioning --bucket $BUCKET"
echo "    aws s3api get-bucket-encryption --bucket $BUCKET"
