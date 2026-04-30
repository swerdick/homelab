#!/usr/bin/env bash
# bootstrap/install-k3s.sh
# Installs k3s as a single-server (control plane + workloads) node on gondor.

set -euo pipefail

# Pin to a specific stable channel rather than `latest` so reinstalls are reproducible.
# Check https://github.com/k3s-io/k3s/releases for current stable.
K3S_VERSION="${K3S_VERSION:-v1.34.6+k3s1}"

curl -sfL https://get.k3s.io | \
  INSTALL_K3S_VERSION="${K3S_VERSION}" \
  INSTALL_K3S_EXEC="server \
    --disable=traefik \
    --disable=servicelb \
    --write-kubeconfig-mode=0644 \
    --node-name=gondor \
    --tls-san=gondor.vingilot.internal \
    --cluster-cidr=10.42.0.0/16 \
    --service-cidr=10.43.0.0/16" \
  sh -

echo "Waiting for k3s to be ready..."
until sudo k3s kubectl get nodes 2>/dev/null | grep -q Ready; do
  sleep 2
done

echo
echo "k3s installed. Node status:"
sudo k3s kubectl get nodes -o wide
echo
echo "Kubeconfig at /etc/rancher/k3s/k3s.yaml"
echo "Copy to thorondor with:"
echo "  scp pseudo@gondor:/etc/rancher/k3s/k3s.yaml ~/.kube/gondor.yaml"
echo "  # then edit the server: line from https://127.0.0.1:6443 to https://gondor:6443"