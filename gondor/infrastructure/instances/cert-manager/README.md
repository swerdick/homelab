# cert-manager ClusterIssuer

The `tirion` ClusterIssuer references tirion's ACME provisioner. cert-manager
uses it to sign Certificate requests across the cluster.

## CA bundle

The `caBundle` field contains the base64-encoded PEM of tirion's root CA cert.
This is what cert-manager uses to verify the HTTPS connection to tirion.

To regenerate the `caBundle` value (e.g., if the CA is rotated):

```bash
base64 -i ~/.step/certs/root_ca.crt | tr -d '\n'
```

Then paste the output into `clusterissuer.yaml` at `spec.acme.caBundle`.

The root CA *certificate* is public information — committing it to Git is fine.
The root CA *private key* lives on tirion in `/etc/step-ca/` and never leaves.

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