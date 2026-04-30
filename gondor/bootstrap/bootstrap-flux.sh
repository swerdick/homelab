#!/usr/bin/env bash
# bootstrap/bootstrap-flux.sh
# Bootstraps Flux against the existing pseudo/homelab repo.
# Requires: GITHUB_TOKEN (classic PAT with `repo` scope) exported in env.

set -euo pipefail

GITHUB_USER="${GITHUB_USER:-pseudo}"
GITHUB_REPO="${GITHUB_REPO:-homelab}"
CLUSTER_NAME="${CLUSTER_NAME:-gondor}"
GITHUB_BRANCH="${GITHUB_BRANCH:-main}"

if [[ -z "${GITHUB_TOKEN:-}" ]]; then
  echo "ERROR: GITHUB_TOKEN is not set."
  echo "Generate a classic PAT with 'repo' scope at https://github.com/settings/tokens"
  echo "Then: export GITHUB_TOKEN=ghp_..."
  exit 1
fi

echo "Pre-flight check..."
flux check --pre

echo "Bootstrapping Flux..."
echo "  owner:    ${GITHUB_USER}"
echo "  repo:     ${GITHUB_REPO}"
echo "  branch:   ${GITHUB_BRANCH}"
echo "  path:     ${CLUSTER_NAME}"
echo

# Note: --personal works for both new and existing repos.
# For an existing repo, flux just commits to the specified path
# rather than creating the repo.
flux bootstrap github \
  --owner="${GITHUB_USER}" \
  --repository="${GITHUB_REPO}" \
  --branch="${GITHUB_BRANCH}" \
  --path="${CLUSTER_NAME}" \
  --personal \
  --components-extra=image-reflector-controller,image-automation-controller

echo
echo "Flux bootstrap complete."
echo "Verify with: flux get kustomizations"
echo
echo "REMINDER: revoke your GITHUB_TOKEN now — Flux uses a deploy key going forward."