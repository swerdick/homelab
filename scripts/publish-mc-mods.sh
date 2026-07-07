#!/usr/bin/env bash
#
# Publish the Minecraft (Fabric) loose binaries to Harbor as OCI artifacts, so
# eregion pulls them from harbor.vingilot.internal/minecraft/* (via ORAS) rather
# than straight from upstream CDNs. First real implementation of the ROADMAP
# "Harbor + ORAS for critical loose binaries" item.
#
# Run from the Mac (thorondor). Reads scripts/mc-artifacts.txt; for each entry:
#   1. downloads the jar/zip from upstream to its canonical filename,
#   2. verifies sha512 (or, if the manifest leaves sha512 blank, prints the
#      computed value so you can paste it into host_vars — used for the Fabric
#      launcher jar, which upstream ships with no checksum),
#   3. `oras push`es it to harbor.vingilot.internal/minecraft/<name>:<tag>.
# Harbor's Trivy then scans each pushed jar.
#
# Idempotent-ish: re-pushing the same content to the same tag is a no-op layer
# in Harbor. Bumping a version = edit the manifest + host_vars, re-run.
#
# Auth: logs in as the Harbor `admin` user, password decrypted from the cluster
# Secret SOPS file (single source of truth), the same source `just tf-harbor`
# uses. Requires: oras, sops, curl, and sha512sum OR shasum on PATH.

set -euo pipefail

REGISTRY="harbor.vingilot.internal"
PROJECT="minecraft"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MANIFEST="${REPO_ROOT}/scripts/mc-artifacts.txt"
ADMIN_SECRET="${REPO_ROOT}/kubernetes/apps/harbor/harbor-admin.yaml"

for bin in oras sops curl; do
  command -v "$bin" >/dev/null 2>&1 || { echo "error: '$bin' not found on PATH" >&2; exit 1; }
done

# sha512 helper — Linux has sha512sum, macOS has `shasum -a 512`.
sha512_of() {
  if command -v sha512sum >/dev/null 2>&1; then
    sha512sum "$1" | awk '{print $1}'
  else
    shasum -a 512 "$1" | awk '{print $1}'
  fi
}

echo ">> Logging in to ${REGISTRY} as admin"
HARBOR_PASSWORD="$(sops --decrypt --extract '["stringData"]["HARBOR_ADMIN_PASSWORD"]' "${ADMIN_SECRET}")"
printf '%s' "${HARBOR_PASSWORD}" | oras login "${REGISTRY}" -u admin --password-stdin

WORKDIR="$(mktemp -d)"
trap 'rm -rf "${WORKDIR}"' EXIT

pushed=0
while IFS='|' read -r name tag filename url sha512; do
  # skip comments + blank lines
  [[ -z "${name}" || "${name}" =~ ^[[:space:]]*# ]] && continue

  ref="${REGISTRY}/${PROJECT}/${name}:${tag}"
  dest="${WORKDIR}/${filename}"

  echo ">> ${name}:${tag}"
  echo "   fetch ${url}"
  curl -fsSL -o "${dest}" "${url}"

  got="$(sha512_of "${dest}")"
  if [[ -n "${sha512// /}" ]]; then
    if [[ "${got}" != "${sha512}" ]]; then
      echo "   ERROR: sha512 mismatch for ${filename}" >&2
      echo "     expected ${sha512}" >&2
      echo "     got      ${got}" >&2
      exit 1
    fi
    echo "   sha512 OK"
  else
    echo "   sha512 (record this in host_vars): ${got}"
  fi

  # media type by extension so Harbor/Trivy see a jar/zip layer
  case "${filename}" in
    *.jar) media="application/java-archive" ;;
    *.zip) media="application/zip" ;;
    *)     media="application/octet-stream" ;;
  esac

  ( cd "${WORKDIR}" && oras push "${ref}" \
      --artifact-type "application/vnd.minecraft.artifact" \
      "${filename}:${media}" )
  pushed=$((pushed + 1))
done < "${MANIFEST}"

echo ">> done: ${pushed} artifact(s) pushed to ${REGISTRY}/${PROJECT}"
