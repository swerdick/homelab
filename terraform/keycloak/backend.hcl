# Partial backend config for the Keycloak app stack — fed to
# `tofu init -backend-config=backend.hcl`. Same bucket as the proxmox stack,
# separate key so the two stacks keep independent state.

bucket = "vingilot-homelab-tfstate"
region = "us-east-2"
key    = "homelab/keycloak.tfstate"
