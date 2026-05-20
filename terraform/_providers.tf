# The bpg/proxmox provider talks to PVE over the REST API. SSH is not
# configured because none of our planned LXC/VM resources need the
# SSH-only operations (snippet uploads, lxc[n] idmap entries, local-file
# disk imports). If a future resource needs SSH, add an `ssh {}` block
# here — see bpg's docs/index.md "When is SSH Required?" table.
#
# `insecure = false`: earendil's PVE cert is signed by tirion's internal
# CA which is in the local trust store (the operator's mac runs the
# distribute-root-ca play, and brew-installed terraform uses the system
# trust store on macOS). No cert-verification skip needed.

provider "proxmox" {
  endpoint = var.pve_endpoint
  insecure = false
  # api_token is intentionally omitted — bpg reads PROXMOX_VE_API_TOKEN
  # from the environment, which the justfile `tf` recipe sources from SOPS.
}
