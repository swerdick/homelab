# Datacenter-level options (/etc/pve/datacenter.cfg).
#
# Singleton resource — there's only one cluster (which is just `earendil`
# today since we're not running an actual PVE cluster, just a single node).
# Most fields are null/unset; PVE's installer defaults are reasonable for
# everything we don't explicitly care about.
#
# If/when we want to set the default console type, HA shutdown policy,
# migration network, etc., they belong here.

# `proxmox_cluster_options` (no `_virtual_environment_` prefix) is bpg's
# successor for this resource; the old name is deprecated and slated for
# removal in v1.0. The other resources in this project still use the
# `proxmox_virtual_environment_*` namespace because bpg hasn't renamed
# them yet.
resource "proxmox_cluster_options" "datacenter" {
  keyboard = "en-us"
  # mac_prefix was auto-assigned by the PVE installer at install time;
  # codifying it here ensures a fresh-rebuild PVE keeps the same prefix
  # (so any hand-set MACs in `terraform/*.tf` resources stay consistent
  # with new auto-assigned ones).
  mac_prefix = "BC:24:11"
}
