# Partial backend config for the Harbor app stack — fed to
# `tofu init -backend-config=backend.hcl`. Same bucket as the proxmox + keycloak
# stacks, separate key so the three stacks keep independent state.

bucket = "vingilot-homelab-tfstate"
region = "us-east-2"
key    = "homelab/harbor.tfstate"
