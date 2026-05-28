# Keycloak realm configuration, managed via the keycloak/keycloak provider.
#
# The `vingilot` realm itself is intentionally NOT managed here (yet) — it was
# created by hand, and a `keycloak_realm` resource carries dozens of settings
# that would churn the plan (cf. the bpg import quirks). We own only the *app
# clients*, so `realm_id` is a plain string. Codifying the realm later is a
# one-line `just tf import` if we decide to.

# --- Immich (OIDC) -----------------------------------------------------------
# Confidential authorization-code client. Immich fetches the realm's discovery
# doc and redirects back to these URIs (web app + mobile deep link). The
# openid/email/profile scopes Immich requests are covered by Keycloak's default
# client scopes, so no explicit scope mappers are needed for basic SSO.
resource "keycloak_openid_client" "immich" {
  realm_id  = "vingilot"
  client_id = "immich"
  name      = "Immich"
  enabled   = true

  access_type                  = "CONFIDENTIAL"
  standard_flow_enabled        = true
  implicit_flow_enabled        = false
  direct_access_grants_enabled = false
  service_accounts_enabled     = false

  valid_redirect_uris = [
    "https://immich.vingilot.internal/auth/login",
    "https://immich.vingilot.internal/user-settings",
    "app.immich:///oauth-callback", # mobile app
  ]

  web_origins = [
    "https://immich.vingilot.internal",
  ]
}

# Retrieve with `just tf output -raw immich_oidc_client_secret` → paste into
# Immich Admin → Settings → OAuth (Client Secret). Marked sensitive so it never
# prints in plan/apply output.
output "immich_oidc_client_secret" {
  value     = keycloak_openid_client.immich.client_secret
  sensitive = true
}
