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
  provider_name = "quay"
  endpoint_url  = "https://quay.io"
  description   = "Quay.io proxy."
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
  registry_id            = harbor_registry.dockerhub.id
}

resource "harbor_project" "ghcr" {
  name                   = "ghcr"
  public                 = true
  vulnerability_scanning = true
  auto_sbom_generation   = false
  storage_quota          = -1
  registry_id            = harbor_registry.ghcr.id
}

resource "harbor_project" "quay" {
  name                   = "quay"
  public                 = true
  vulnerability_scanning = true
  auto_sbom_generation   = false
  storage_quota          = -1
  registry_id            = harbor_registry.quay.id
}

resource "harbor_project" "registry_k8s" {
  name                   = "registry-k8s"
  public                 = true
  vulnerability_scanning = true
  auto_sbom_generation   = false
  storage_quota          = -1
  registry_id            = harbor_registry.registry_k8s.id
}
