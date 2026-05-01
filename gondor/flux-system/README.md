# Flux on gondor

Flux 2.8 is bootstrapped on this cluster, syncing from this repository at path `./gondor`. This document covers authentication, manual bootstrap procedures, and recovery scenarios.

## Authentication

Flux authenticates to GitHub using a **GitHub App**, not a personal access token. The App credentials live in the `flux-system` Kubernetes Secret in the `flux-system` namespace.

### GitHub App details

- **Name:** `vingilot-flux`
- **Permissions:** Repository → Contents (read), Metadata (read)
- **Installed on:** `swerdick/homelab` only
- **App ID and Installation ID:**
- **Private key:**

### Required GitRepository spec fields

These three fields must all be present on the `flux-system` GitRepository:

```yaml
spec:
  url: https://github.com/swerdick/homelab.git    # HTTPS, not SSH
  provider: github                                 # Required for App-shaped secrets (Flux 2.5+)
  secretRef:
    name: flux-system                              # The secret created by `flux create secret githubapp`
```

Missing any of the three causes confusing errors. The most common is forgetting `provider: github`, which yields:

```
secretRef 'flux-system/flux-system' has github app data but provider is not set to github
```

## Bootstrap from scratch

If gondor needs to be rebuilt and Flux needs to be re-bootstrapped against this repository:

1. Install k3s and confirm cluster is reachable (see `gondor/bootstrap/install-k3s.sh`)
2. Install the Flux CLI on thorondor: `brew install fluxcd/tap/flux`
3. Run the bootstrap process documented in `gondor/bootstrap/bootstrap-flux.sh`
4. After Flux is running, swap to GitHub App auth using the procedure in `gondor/bootstrap/setup-github-app-auth.sh`

## Rotating the GitHub App private key

GitHub App private keys should be rotated periodically (e.g., yearly) and immediately if compromised:

1. In GitHub: App settings → Private keys → Generate a new private key (downloads `.pem`)
2. Save the new key in 1Password
3. Recreate the secret in the cluster:
   ```bash
   flux create secret githubapp flux-system \
       --namespace=flux-system \
       --app-id=<APP_ID> \
       --app-installation-id=<INSTALLATION_ID> \
       --app-private-key=$HOME/Downloads/<new-key>.pem
   ```
4. Force a reconcile: `flux reconcile source git flux-system`
5. Once verified working, delete the old private key in GitHub App settings
6. Securely delete the local `.pem` file: `rm -P $HOME/Downloads/<new-key>.pem`

## Observability

Flux state is observable via:

- **`flux` CLI** — primary interface. `flux get all -A`, `flux events`, `flux logs`.
- **`k9s`** — for general Kubernetes browsing including Flux CRDs.
- **Capacitor Next** — optional local-launched browser UI: `brew install gimlet-io/capacitor/capacitor && capacitor`. Decoupled from Flux installation; runs on thorondor and talks to whichever cluster the active kubectl context points at.

The in-cluster Capacitor was tried and removed due to Flux 2.8 API compatibility issues. See `docs/UI-EXPERIMENTS.md` for the full story.
