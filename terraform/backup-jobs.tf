# Datacenter-level backup jobs (vzdump entries in /etc/pve/jobs.cfg).
#
# Four jobs total: two enabled (the active backup rotation), two disabled
# (legacy jobs kept around in case we want to re-enable). The disabled
# ones are imported with enabled=false to match reality; delete them via
# PVE UI if you ever decide they're truly cruft.
#
# Job IDs are PVE-generated UUIDs (backup-<8hex>-<4hex>). Not pretty but
# changing them would require destroy+create — TF resource names
# (nightly_guests etc.) are the human-readable handle.
#
# bpg's backup_job resource doesn't model the `exclude` field (excluding
# specific VMIDs from an `all=true` job). The legacy_all_to_pbs job has
# `exclude 130` in jobs.cfg but TF can't see it. Since that job is
# disabled, this gap doesn't affect anything operationally.

# Every job below has `lifecycle { ignore_changes = [fleecing] }`. bpg's
# import populates `fleecing = { enabled = false }` into state, but it's
# a feature we don't actively configure — same null→default state-fill
# pattern as the VM/LXC timeout attrs. ignore_changes only accepts literal
# attribute names so the block can't be DRYed via locals or variables.

resource "proxmox_backup_job" "nightly_guests" {
  id             = "backup-12b42abc-89fd"
  schedule       = "21:00"
  storage        = "backups"
  vmid           = ["120", "121", "140", "131", "141"]
  enabled        = true
  compress       = "zstd"
  mode           = "snapshot"
  notes_template = "{{guestname}}"
  prune_backups = {
    keep-daily   = "7"
    keep-monthly = "6"
    keep-weekly  = "4"
  }
  lifecycle {
    ignore_changes = [fleecing]
  }
}

resource "proxmox_backup_job" "erebor_config_weekly" {
  id             = "backup-43aa665e-dcfd"
  schedule       = "sun 04:00"
  storage        = "backups"
  vmid           = ["130"]
  enabled        = true
  compress       = "zstd"
  mode           = "snapshot"
  notes_template = "pbs-config -- {{guestname}}"
  prune_backups = {
    keep-last = "8"
  }
  lifecycle {
    ignore_changes = [fleecing]
  }
}

resource "proxmox_backup_job" "legacy_samba_nfs" {
  id             = "backup-c3e36b01-9fa9"
  schedule       = "21:00"
  storage        = "backups"
  vmid           = ["120", "121"]
  enabled        = false
  compress       = "zstd"
  mode           = "snapshot"
  node           = "earendil"
  notes_template = "{{guestname}} -- {{node}}"
  prune_backups = {
    keep-daily   = "7"
    keep-last    = "3"
    keep-monthly = "6"
    keep-weekly  = "4"
  }
  lifecycle {
    ignore_changes = [fleecing]
  }
}

resource "proxmox_backup_job" "legacy_all_to_pbs" {
  id             = "backup-66ed8128-0c86"
  schedule       = "21:00"
  storage        = "main"
  all            = true
  enabled        = false
  mode           = "snapshot"
  notes_template = "{{guestname}}"
  prune_backups = {
    keep-daily   = "7"
    keep-monthly = "6"
    keep-weekly  = "4"
  }
  lifecycle {
    ignore_changes = [fleecing]
  }
}
