# cert-manager ClusterIssuer

This directory contains the `ClusterIssuer` resource that references tirion's
ACME provisioner. cert-manager uses it to sign Certificate requests across the
cluster.

## Manual prerequisite: tirion-root-ca Secret

The ClusterIssuer references a Kubernetes Secret containing tirion's root CA
certificate so cert-manager can verify the HTTPS connection to the ACME endpoint.

This Secret is created manually rather than via GitOps because:

1. It existed before SOPS+age encryption was set up
2. Once SOPS is set up, the Secret will be moved into Git and this README updated

### To create the Secret

The tirion root CA cert was distributed to thorondor by
`gondor/bootstrap/distribute-root-ca.sh`. On thorondor it lives somewhere under
`~/.step/` (run `step path` to find the exact location).

\`\`\`bash
# From thorondor:
kubectl create secret generic tirion-root-ca \
--namespace=cert-manager \
--from-file=ca.crt=$HOME/.step/certs/root_ca.crt

# Verify
kubectl -n cert-manager get secret tirion-root-ca
\`\`\`

### Eventual migration

Once SOPS+age is set up:

1. Encrypt the Secret manifest with `sops`
2. Commit the encrypted YAML to this directory
3. Add to `kustomization.yaml`
4. Delete this README's manual instructions
5. Verify cert-manager continues to validate against tirion

## How a cert gets issued

\`\`\`
HTTPRoute or Certificate references
↓
ClusterIssuer "tirion"
↓ (ACME order)
tirion.vingilot.internal/acme/acme/directory
↓ (HTTP-01 challenge)
cert-manager creates temporary HTTPRoute on the vingilot Gateway
↓
step-ca on tirion fetches /.well-known/acme-challenge/<token>
↓ (validation passes)
Certificate issued, written to a Secret in the requesting namespace
\`\`\`