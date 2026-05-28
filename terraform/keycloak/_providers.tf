# Keycloak admin REST API. Auth is the client-credentials grant via a dedicated
# `terraform` service-account client in the *master* realm (created once in the
# UI + granted the master `admin` role). url + client_id are non-secret and live
# here; the client secret comes from KEYCLOAK_CLIENT_SECRET, which the justfile
# `tf-keycloak` recipe sources from SOPS per-invocation. Authenticates against
# the master realm (provider default), where the service account lives.
#
# No `insecure`/`tls_insecure_skip_verify` — keycloak.vingilot.internal's tirion
# cert is in the mac's system trust store (same as the proxmox endpoint).
provider "keycloak" {
  url       = var.keycloak_url
  client_id = "terraform"
}
