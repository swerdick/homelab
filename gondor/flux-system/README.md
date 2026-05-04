# Flux on gondor

Flux 2.8 is bootstrapped on this cluster, syncing from this repository at path `./gondor`.

## Bootstrap from scratch

If gondor needs to be rebuilt and Flux needs to be re-bootstrapped against this repository:

1. Install k3s and confirm cluster is reachable (see `gondor/bootstrap/install-k3s.sh`)
2. Install the Flux CLI on thorondor: `brew install fluxcd/tap/flux`
3. Run the bootstrap process documented in `gondor/bootstrap/bootstrap-flux.sh`
4. Swap to GitHub App auth using `gondor/bootstrap/setup-github-app-auth.sh`
5. Set up SOPS decryption using `gondor/bootstrap/setup-sops.sh`
6. Force a reconcile: `flux reconcile source git flux-system`

## Authentication (GitHub App)

Flux authenticates to GitHub using a GitHub App, not a personal access token. The App credentials live in the `flux-system` Kubernetes Secret in the `flux-system` namespace.

### GitHub App details

- **Name:** `vingilot-flux`
- **Permissions:** Repository → Contents (read), Metadata (read)
- **Installed on:** `swerdick/homelab` only
- **App ID, Installation ID, and Private Key:** stored in Bitwarden as "vingilot-flux GitHub App"

### Required GitRepository spec fields

These three fields must all be present on the `flux-system` GitRepository:

```yaml
spec:
  url: https://github.com/swerdick/homelab.git    # HTTPS, not SSH
  provider: github                                 # Required for App-shaped secrets (Flux 2.5+)
  secretRef:
    name: flux-system                              # Created by `flux create secret githubapp`
```

Missing any of the three causes confusing errors. The most common is forgetting `provider: github`, which yields:

```
secretRef 'flux-system/flux-system' has github app data but provider is not set to github
```

### Rotating the GitHub App private key

GitHub App private keys should be rotated periodically (e.g., yearly) and immediately if compromised:

1. In GitHub: App settings → Private keys → Generate a new private key (downloads `.pem`)
2. Save the new key in Bitwarden
3. Recreate the secret in the cluster:
   ```bash
   flux create secret githubapp flux-system \
       --namespace=flux-system \
       --app-id=<APP_ID> \
       --app-installation-id=<INSTALLATION_ID> \
       --app-private-key=$HOME/Downloads/<new-key>.pem
   ```
4. Force a reconcile: `flux reconcile source git flux-system`
5. Verify working, then delete the old private key in GitHub App settings
6. Securely delete the local `.pem` file: `rm -P $HOME/Downloads/<new-key>.pem`

## Encryption (SOPS+age)

All Flux Kustomizations in this repo are configured with `decryption.provider: sops`, referencing a Secret named `sops-age` in the `flux-system` namespace. This Secret holds the age private key that decrypts SOPS-encrypted manifests under `gondor/`.

The same configuration is on every Flux Kustomization (`flux-system`, `infrastructure-controllers`, `infrastructure-instances`) — each Kustomization independently fetches and decrypts its own resources, so the `decryption:` block must be present on each.

### Encrypting a new Secret

The repo's `.sops.yaml` configures SOPS to encrypt `data:` and `stringData:` fields in any YAML under `gondor/`. To create a new encrypted Secret:

```bash
# Write the plaintext Secret manifest
cat > /tmp/grafana-admin.yaml <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: grafana-admin
  namespace: monitoring
type: Opaque
stringData:
  admin-password: "actual-password-value"
EOF

# Encrypt in place
sops --encrypt --in-place /tmp/grafana-admin.yaml

# Commit the encrypted result
mv /tmp/grafana-admin.yaml gondor/apps/observability/secrets/
git add gondor/apps/observability/secrets/grafana-admin.yaml
git commit -m "feat(grafana): set admin password Secret"
```

### Decrypting locally for inspection

```bash
sops --decrypt path/to/encrypted.yaml
```

Reads `~/.config/sops/age/keys.txt` automatically.

### Rotating the age key

If the age key is ever compromised:

1. Generate a new age key with `age-keygen -o ~/.config/sops/age/keys.txt`
2. Update `.sops.yaml` to point to the new public key
3. Re-encrypt every encrypted file: `sops updatekeys path/to/file.yaml`
4. Update Bitwarden's stored key
5. Re-run `setup-sops.sh` to push the new private key to the cluster
6. Force a reconcile so Flux picks up the new key
7. Commit the re-encrypted files

## Observability

- **`flux` CLI** — primary interface: `flux get all -A`, `flux events`, `flux logs`
- **`k9s`** — general Kubernetes browsing including Flux CRDs
- **Capacitor Next** — optional browser UI: `brew install gimlet-io/capacitor/capacitor && capacitor`

The in-cluster Capacitor was tried and removed due to Flux 2.8 API compatibility issues. See `docs/UI-EXPERIMENTS.md` for the full story.