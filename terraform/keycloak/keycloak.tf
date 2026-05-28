# Keycloak realm configuration, managed via the keycloak/keycloak provider.
#
# The `vingilot` realm itself is intentionally NOT managed here (yet) — it was
# created by hand, and a `keycloak_realm` resource carries dozens of settings
# that would churn the plan (cf. the bpg import quirks). We own only the *app
# clients*, so `realm_id` is a plain string. Codifying the realm later is a
# one-line `just tf-keycloak import` if we decide to.

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

# Retrieve with `just tf-keycloak output -raw immich_oidc_client_secret` → paste
# into Immich Admin → Settings → OAuth (Client Secret). Marked sensitive so it
# never prints in plan/apply output.
output "immich_oidc_client_secret" {
  value     = keycloak_openid_client.immich.client_secret
  sensitive = true
}

# --- Grafana (OIDC) ----------------------------------------------------------
# Confidential authorization-code client for kube-prometheus-stack Grafana.
# Grafana constructs the callback as `<server.root_url>/login/generic_oauth`,
# so the redirect URI is set explicitly to that path. Same default client scopes
# (openid/email/profile) as immich.
resource "keycloak_openid_client" "grafana" {
  realm_id  = "vingilot"
  client_id = "grafana"
  name      = "Grafana"
  enabled   = true

  access_type                  = "CONFIDENTIAL"
  standard_flow_enabled        = true
  implicit_flow_enabled        = false
  direct_access_grants_enabled = false
  service_accounts_enabled     = false

  valid_redirect_uris = [
    "https://grafana.vingilot.internal/login/generic_oauth",
  ]

  web_origins = [
    "https://grafana.vingilot.internal",
  ]
}

# Retrieve with `just tf-keycloak output -raw grafana_oidc_client_secret` →
# SOPS-encrypt into gondor/apps/observability/grafana-oauth.yaml under key
# `client_secret`; the Grafana chart picks it up via envValueFrom on
# GF_AUTH_GENERIC_OAUTH_CLIENT_SECRET.
output "grafana_oidc_client_secret" {
  value     = keycloak_openid_client.grafana.client_secret
  sensitive = true
}

# --- Harbor (OIDC) -----------------------------------------------------------
# Confidential auth-code client for the Harbor container registry. Harbor's
# redirect URI is /c/oidc/callback (Harbor also displays it at the bottom of
# its OIDC config page — verify against that on first setup). Default scopes
# openid/email/profile are covered by Keycloak's default client scopes.
resource "keycloak_openid_client" "harbor" {
  realm_id  = "vingilot"
  client_id = "harbor"
  name      = "Harbor"
  enabled   = true

  access_type                  = "CONFIDENTIAL"
  standard_flow_enabled        = true
  implicit_flow_enabled        = false
  direct_access_grants_enabled = false
  service_accounts_enabled     = false

  valid_redirect_uris = [
    "https://harbor.vingilot.internal/c/oidc/callback",
  ]

  web_origins = [
    "https://harbor.vingilot.internal",
  ]
}

# Retrieve with `just tf-keycloak output -raw harbor_oidc_client_secret` →
# paste into Harbor Admin → Configuration → Authentication → OIDC Client Secret.
# Harbor stores OIDC config in its own DB (no SOPS Secret on our side, unlike
# Grafana's Helm-values flow). Marked sensitive so plan/apply doesn't print it.
output "harbor_oidc_client_secret" {
  value     = keycloak_openid_client.harbor.client_secret
  sensitive = true
}

# --- Groups (vingilot realm) -------------------------------------------------
# Two flat groups drive app-permission mapping. Membership is hand-managed in
# the Keycloak UI (humans-in-UI per [[project-sso-identity-model]]); add your
# `pseudo` user to `homelab-admins` once after `apply`. New users default to
# the lowest role in each app until added to a group.

resource "keycloak_group" "admins" {
  realm_id = "vingilot"
  name     = "homelab-admins"
}

resource "keycloak_group" "readonly" {
  realm_id = "vingilot"
  name     = "homelab-readonly"
}

# --- Group-membership claim mappers (one per OIDC client) --------------------
# Each client gets a Group Membership mapper so its token + userinfo carry a
# flat `groups: [...]` claim (full_path=false → "homelab-admins", not
# "/homelab-admins"). Apps consume it differently:
#   - Grafana: JMESPath in auth.generic_oauth.role_attribute_path (Helm values)
#   - Harbor:  Group Claim Name + OIDC Admin Group fields (Admin UI config)
#   - Immich:  not yet — Immich's role_claim_name wants a custom claim with
#              conditional logic (Keycloak Script Mapper / per-user attribute),
#              deferred. Bump `pseudo` to Admin in Immich's UI for now.
#
# Adding the mapper directly to each client (rather than via a shared client
# scope) means no scope-list changes in the existing OAuth configs — the claim
# is always emitted, no `openid groups` extra-scope dance needed.

resource "keycloak_openid_group_membership_protocol_mapper" "immich_groups" {
  realm_id   = "vingilot"
  client_id  = keycloak_openid_client.immich.id
  name       = "groups"
  claim_name = "groups"
  full_path  = false

  add_to_id_token     = true
  add_to_access_token = true
  add_to_userinfo     = true
}

resource "keycloak_openid_group_membership_protocol_mapper" "grafana_groups" {
  realm_id   = "vingilot"
  client_id  = keycloak_openid_client.grafana.id
  name       = "groups"
  claim_name = "groups"
  full_path  = false

  add_to_id_token     = true
  add_to_access_token = true
  add_to_userinfo     = true
}

resource "keycloak_openid_group_membership_protocol_mapper" "harbor_groups" {
  realm_id   = "vingilot"
  client_id  = keycloak_openid_client.harbor.id
  name       = "groups"
  claim_name = "groups"
  full_path  = false

  add_to_id_token     = true
  add_to_access_token = true
  add_to_userinfo     = true
}
