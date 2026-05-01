# Kubernetes Gateway API CRDs

This directory vendors the Gateway API CRDs from the upstream
`kubernetes-sigs/gateway-api` project. They install cluster-scoped CRDs:
`GatewayClass`, `Gateway`, `HTTPRoute`, `ReferenceGrant`, and a few others.

These CRDs are required by Traefik's `kubernetesGateway` provider, which is
enabled in `../traefik/helmrelease.yaml`.

## Why vendored

Gateway API isn't distributed as a Helm chart. The upstream project publishes
a single YAML manifest per release (the "standard channel" install bundle).
Vendoring this file into the repo keeps everything pinned and GitOps-managed.

## Pinned version

`v1.5.0` (released Feb 2026). Standard channel only — no experimental features.

## Refreshing

To upgrade to a newer Gateway API release:

\`\`\`bash
GATEWAY_API_VERSION=v1.5.0
curl -fsSL \
https://github.com/kubernetes-sigs/gateway-api/releases/download/${GATEWAY_API_VERSION}/standard-install.yaml \
> gondor/infrastructure/controllers/gateway-api/standard-install.yaml

git diff gondor/infrastructure/controllers/gateway-api/standard-install.yaml
git add gondor/infrastructure/controllers/gateway-api/standard-install.yaml
git commit -m "chore(gateway-api): upgrade CRDs to ${GATEWAY_API_VERSION}"
\`\`\`