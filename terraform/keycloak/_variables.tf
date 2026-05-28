# Keycloak base URL — non-sensitive (it's the public internal hostname). The
# provider's client_id is set in _providers.tf; the client secret comes via
# KEYCLOAK_CLIENT_SECRET from the justfile `tf-keycloak` recipe (SOPS), so no
# TF variable for the secret.
variable "keycloak_url" {
  description = "Keycloak base URL, no trailing path (e.g. https://keycloak.vingilot.internal)."
  type        = string
  default     = "https://keycloak.vingilot.internal"
}
