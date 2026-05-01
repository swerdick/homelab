#!/usr/bin/env bash
# Migrates Flux's authentication from PAT to GitHub App credentials.
#
# This is a one-time setup procedure. Re-running is safe but unnecessary
# unless rotating the App's private key.
#
# Prerequisites:
# - Flux is already bootstrapped (via `flux bootstrap github --token-auth`)
#   and reconciling against this repo
# - You've created a GitHub App and installed it on the repo
# - You have the App ID, Installation ID, and downloaded private key
#
# Reference: see gondor/flux-system/README.md for the full procedure.

set -euo pipefail

# --- GitHub App creation (manual, do this first) ---
# 1. https://github.com/settings/apps -> New GitHub App
#    - Name: vingilot-flux (or any unique name)
#    - Homepage URL: <anything, e.g. this repo's URL>
#    - Webhook -> Active: UNCHECK
#    - Repository permissions:
#         * Contents: Read-only
#         * Metadata: Read-only (auto-selected)
#    - Where can this App be installed: Only on this account
# 2. After creation:
#    - Copy the App ID from the General tab
#    - Generate a private key (downloads a .pem file)
#    - Install the App on the homelab repo only
#    - From the install URL (https://github.com/settings/installations/<ID>),
#      copy the Installation ID
# 3. Store App ID, Installation ID, and the .pem in 1Password.

# --- Required inputs (export before running, or hardcode for one-off) ---
: "${GITHUB_APP_ID:?Set GITHUB_APP_ID environment variable}"
: "${GITHUB_APP_INSTALLATION_ID:?Set GITHUB_APP_INSTALLATION_ID environment variable}"
: "${GITHUB_APP_PRIVATE_KEY_PATH:?Set GITHUB_APP_PRIVATE_KEY_PATH to the .pem file path}"

if [[ ! -f "${GITHUB_APP_PRIVATE_KEY_PATH}" ]]; then
    echo "ERROR: private key file not found at ${GITHUB_APP_PRIVATE_KEY_PATH}"
    exit 1
fi

# --- Step 1: Replace the flux-system secret with GitHub App credentials ---
# This swaps the in-cluster auth from PAT to the GitHub App. The secret name
# stays 'flux-system' so the existing GitRepository continues to reference it.
echo "[1/3] Creating GitHub App secret..."
flux create secret githubapp flux-system \
    --namespace=flux-system \
    --app-id="${GITHUB_APP_ID}" \
    --app-installation-id="${GITHUB_APP_INSTALLATION_ID}" \
    --app-private-key="${GITHUB_APP_PRIVATE_KEY_PATH}"

# --- Step 2: Patch the GitRepository to use HTTPS + provider: github ---
# `flux bootstrap github --token-auth` originally configures HTTPS with PAT-based
# auth. The GitRepository needs `provider: github` to interpret the new
# App-shaped secret correctly (this field was added in Flux 2.5).
#
# If the original bootstrap used SSH, the URL also needs to switch to HTTPS.
echo "[2/3] Patching GitRepository for GitHub App auth..."
kubectl -n flux-system patch gitrepository flux-system --type=merge -p '{
  "spec": {
    "provider": "github",
    "url": "https://github.com/swerdick/homelab.git"
  }
}'

# --- Step 3: Force a reconcile and verify ---
echo "[3/3] Forcing reconciliation..."
flux reconcile source git flux-system

echo
echo "✓ Migration complete. Verify with:"
echo "    flux get sources git -A"
echo "    kubectl logs -n flux-system deployment/source-controller --tail=20 | grep -iE 'auth|error'"
echo
echo "POST-CHECKLIST:"
echo "  [ ] Update gondor/flux-system/gotk-sync.yaml to include 'provider: github' and HTTPS url"
echo "      (drift detection will revert the live patch otherwise)"
echo "  [ ] Revoke the old PAT at https://github.com/settings/tokens"
echo "  [ ] Securely delete the local .pem file: rm -P ${GITHUB_APP_PRIVATE_KEY_PATH}"
echo "  [ ] Confirm App private key is in 1Password"
