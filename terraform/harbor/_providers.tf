# Harbor admin REST API. Auth is local `admin` (Harbor's built-in superuser),
# not the Keycloak SSO identity — the TF provider needs full admin-API access
# and the local admin is the documented break-glass path that always works
# even if Keycloak is down (see [[project_sso_identity_model]]).
#
# url is non-secret and lives here; HARBOR_USERNAME + HARBOR_PASSWORD come
# from the justfile `tf-harbor` recipe per-invocation (SOPS-decrypted from
# the cluster's harbor-admin Secret — single source of truth).
#
# `insecure = false` — harbor.vingilot.internal's tirion cert is in the mac's
# system trust store (CA distribution covers the operator workstation).
provider "harbor" {
  url      = var.harbor_url
  insecure = false
}
