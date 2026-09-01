# Harbor proxy-cache configuration, managed via the goharbor/harbor provider.
#
# Each upstream OCI registry gets a paired (harbor_registry, harbor_project)
# resource. The registry resource is the upstream endpoint Harbor pulls from;
# the project is the local namespace whose `registry_id` enables Proxy Cache
# mode. containerd routes through these via the mirror entries in
# ansible/templates/k3s-registries.yaml.j2 (see setup-k3s-registries.yaml +
# ROADMAP — "Harbor as upstream-registry proxy/cache").
#
# Provider-shape gap: the "Serve stale content when upstream is unavailable"
# project toggle is a Harbor API field but is NOT exposed in
# goharbor/harbor (3.x as of writing). TF creates new projects with it OFF;
# enable it manually via Projects → <project> → Configuration after
# `tofu apply` on each of the three new projects. The existing dockerhub
# project already has it enabled (set at creation via UI before import);
# TF won't disturb fields it doesn't manage. Track the provider release
# notes for a `proxy_cache_*` field and move these toggles into TF when
# it lands.

# --- Upstream registry endpoints --------------------------------------------

resource "harbor_registry" "dockerhub" {
  name          = "dockerhub"
  provider_name = "docker-hub"
  endpoint_url  = "https://hub.docker.com"
  description   = "Docker Hub proxy. Anonymous pull (no access_id/access_secret); upgrade to a Docker Hub PAT if anonymous rate-limits become a problem."
}

resource "harbor_registry" "ghcr" {
  name          = "ghcr"
  provider_name = "github"
  endpoint_url  = "https://ghcr.io"
  description   = "GitHub Container Registry proxy. Anonymous pull works for public packages; add a fine-grained PAT under access_id/access_secret if/when we need private ghcr.io repos."
}

resource "harbor_registry" "quay" {
  name          = "quay"
  provider_name = "docker-registry"
  endpoint_url  = "https://quay.io"
  description   = "Quay.io proxy. Generic docker-registry adapter, NOT the quay type: this Harbor rejects proxy-cache projects on the quay adapter (400 'unsupported registry type quay', observed 2026-09-01 via both API and TF); quay.io speaks plain OCI v2 so the generic adapter proxies it fine — same approach as registry-k8s."
}

resource "harbor_registry" "registry_k8s" {
  name          = "registry-k8s"
  provider_name = "docker-registry"
  endpoint_url  = "https://registry.k8s.io"
  description   = "Kubernetes upstream registry proxy. No dedicated provider type in goharbor/harbor — Harbor treats it as a generic Docker Registry endpoint."
}

# --- Proxy-cache projects (one per upstream) --------------------------------
#
# Common-shape projects: public for anonymous pulls from cluster nodes,
# auto-scan-on-push so Trivy populates CVE data on every cached image,
# unlimited quota (revisit if blob accumulation becomes a concern), SBOM
# generation off (enable later if/when an SBOM consumer exists).
# `deployment_security` left unset → vulnerable images are not blocked
# from pulls, which is the deliberate "visibility, not gating" posture.

resource "harbor_project" "dockerhub" {
  name                   = "dockerhub"
  public                 = true
  vulnerability_scanning = true
  auto_sbom_generation   = false
  storage_quota          = -1
  registry_id            = harbor_registry.dockerhub.registry_id
}

resource "harbor_project" "ghcr" {
  name                   = "ghcr"
  public                 = true
  vulnerability_scanning = true
  auto_sbom_generation   = false
  storage_quota          = -1
  registry_id            = harbor_registry.ghcr.registry_id
}

resource "harbor_project" "quay" {
  name                   = "quay"
  public                 = true
  vulnerability_scanning = true
  auto_sbom_generation   = false
  storage_quota          = -1
  registry_id            = harbor_registry.quay.registry_id
}

resource "harbor_project" "registry_k8s" {
  name                   = "registry-k8s"
  public                 = true
  vulnerability_scanning = true
  auto_sbom_generation   = false
  storage_quota          = -1
  registry_id            = harbor_registry.registry_k8s.registry_id
}

# --- Hosted projects (we push, not proxy-cache) -----------------------------
#
# `minecraft` holds "loose" binaries the host playbooks used to pull straight
# from upstream CDNs (Fabric/mod/datapack jars) — see ROADMAP "Harbor + ORAS
# for critical loose binaries". Pushed as OCI artifacts via
# scripts/publish-mc-mods.sh (ORAS) and pulled onto eregion by
# ansible/playbooks/install-fabric-mc.yaml. No `registry_id` → a normal hosted
# project (not a proxy cache). `public = true` so eregion pulls anonymously —
# these are game mods, not secrets, and it keeps a Harbor robot credential off
# the LXC (only tirion CA trust is needed, already distributed). Trivy still
# scans every pushed jar (vulnerability_scanning = true); Java archives are
# fully supported. Pushes authenticate as the Harbor admin (the same SOPS cred
# `just tf-harbor` already uses); swap to a push-scoped robot account later if
# least-privilege becomes worth the extra moving part.
resource "harbor_project" "minecraft" {
  name                   = "minecraft"
  public                 = true
  vulnerability_scanning = true
  auto_sbom_generation   = false
  storage_quota          = -1
}

# --- Cache lifecycle: retention + garbage collection ------------------------
#
# Proxy caches grow monotonically without this — a single AI image is ~14GB
# per date tag (the ComfyUI cache that motivated PR #45/#46). One policy
# shape for every proxy project, rules OR'd (union retained, rest pruned):
#   - keep the 3 most-recently-PULLED artifacts per repo
#   - keep anything pulled within the last 30 days
# i.e. always the active 3, plus a 30-day grace so rapid iteration never
# loses an image mid-debug. Untagged artifacts are in scope — proxy caches
# hold untagged child manifests. Retention only unlinks; the GC run an hour
# later returns the disk space. Sat 16:00/17:00 UTC sits in the fleet's
# awake band clear of the backup lanes; a Saturday the fleet never wakes
# defers a week (cleanup, not backup — no catch-up needed). minecraft
# (hosted, pushed) deliberately has NO policy: the mods are a system of
# record, not a cache.

locals {
  proxy_cache_projects = {
    dockerhub    = harbor_project.dockerhub.project_id
    ghcr         = harbor_project.ghcr.project_id
    quay         = harbor_project.quay.project_id
    registry_k8s = harbor_project.registry_k8s.project_id
  }
}

resource "harbor_retention_policy" "proxy_cache" {
  for_each = local.proxy_cache_projects

  scope    = each.value
  schedule = "0 0 16 * * 6"

  lifecycle {
    # goharbor's flavor of the bpg state-fill quirk: create sends the numeric
    # project id, but Read stores scope back as "/projects/N" — a perpetual
    # ForceNew replace loop without this. scope is pure linkage and never
    # legitimately changes after creation (one policy per project, forever).
    ignore_changes = [scope]
  }

  rule {
    most_recently_pulled = 3
    repo_matching        = "**"
    tag_matching         = "**"
    untagged_artifacts   = true
  }

  rule {
    n_days_since_last_pull = 30
    repo_matching          = "**"
    tag_matching           = "**"
    untagged_artifacts     = true
  }
}

resource "harbor_garbage_collection" "main" {
  schedule = "0 0 17 * * 6"
  # Retention owns artifact lifecycle (incl. untagged); GC's own untagged
  # sweep stays off so it can never race an index's child manifests.
  delete_untagged = false
}
