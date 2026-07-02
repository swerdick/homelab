#!/usr/bin/env bash
# Bootstraps SOPS+age decryption for Flux on this cluster.
#
# This is a one-time setup (or re-run on cluster rebuild). Decryption uses
# an age key whose public half is in .sops.yaml at the repo root, and whose
# private half is stored in Bitwarden under "homelab age key (SOPS)".
#
# Prerequisites:
# - Flux is already bootstrapped and reconciling against this repo
# - The age private key is available at ~/.config/sops/age/keys.txt
# - The .sops.yaml file at the repo root exists (committed to Git)

set -euo pipefail

KEY_PATH="${HOME}/.config/sops/age/keys.txt"

if [[ ! -f "${KEY_PATH}" ]]; then
    echo "ERROR: age key not found at ${KEY_PATH}"
    echo
    echo "On a fresh machine:"
    echo "  1. Retrieve the age key from Bitwarden ('homelab age key (SOPS)')"
    echo "  2. mkdir -p ~/.config/sops/age"
    echo "  3. Save the entire contents to ${KEY_PATH}"
    echo "  4. Re-run this script"
    exit 1
fi

if ! grep -q "AGE-SECRET-KEY-" "${KEY_PATH}"; then
    echo "ERROR: ${KEY_PATH} does not contain an AGE-SECRET-KEY- line"
    echo "File should contain both '# public key:' and 'AGE-SECRET-KEY-' lines."
    exit 1
fi

# Check if the secret already exists (idempotent re-run)
if kubectl -n flux-system get secret sops-age &>/dev/null; then
    echo "Secret 'sops-age' already exists in flux-system namespace."
    read -rp "Recreate it? (y/N) " confirm
    if [[ "${confirm}" != "y" ]]; then
        echo "Aborted."
        exit 0
    fi
    kubectl -n flux-system delete secret sops-age
fi

echo "Creating sops-age Secret in flux-system namespace..."
cat "${KEY_PATH}" | \
    kubectl -n flux-system create secret generic sops-age \
        --from-file=age.agekey=/dev/stdin

echo "✓ Secret created"
echo
echo "Verify with:"
echo "  kubectl -n flux-system get secret sops-age"
echo
echo "Force a reconcile to pick up SOPS-encrypted resources:"
echo "  flux reconcile source git flux-system"