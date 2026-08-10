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
  id = "backup-12b42abc-89fd"
  # 14:00 earendil-local (America/New_York). The old 21:00 slot sat in prime
  # evening gaming hours and vzdump'ing CT 117 out from under a live session
  # caused visible stutter (diagnosed 2026-08-09). Early afternoon is the
  # quietest reliable window in the on-demand power cycle; the aglarond
  # restic timers (UTC, see descriptions/aglarond.md) are anchored >=45min
  # after this job's worst-case finish across both DST offsets.
  schedule = "14:00"
  # Fleet wake is on-demand, so a day that starts after 14:00 would silently
  # skip the backup without this — and eregion's Minecraft world has no
  # other backup. Catch-up runs are throttled by bwlimit below.
  repeat_missed = true
  storage       = "backups"
  vmid          = ["117", "120", "121", "131", "140", "141", "142"]
  enabled       = true
  compress      = "zstd"
  # 30 MiB/s read cap (KiB/s). Caps compressor throughput too, so the job
  # stays ~1 core even when it collides with an interactive session.
  # ionice deliberately omitted: block-elevator priorities are a no-op on
  # ZFS-backed dir storage.
  bwlimit        = 30720
  zstd           = 1
  mode           = "snapshot"
  notes_template = "{{guestname}}"
  # Local dir target on scratch/backups (300G quota). The fat guests
  # (140 gondor ~16G, 117 anduril ~20G+) blew past the quota under the
  # old 7d/4w/6m policy — and because vzdump only prunes a guest after a
  # *successful* run, the guests too big to fit never pruned themselves,
  # so stale copies snowballed. 3 dailies + 2 weeklies keeps recent
  # restore points local; deeper history lives in B2 via aglarond restic.
  prune_backups = {
    keep-daily  = "3"
    keep-weekly = "2"
  }
  lifecycle {
    ignore_changes = [fleecing]
  }
}

resource "proxmox_backup_job" "erebor_config_weekly" {
  id = "backup-43aa665e-dcfd"
  # Was "sun 04:00" — a slot the fleet never sees awake (nightly shutdown
  # ~23:15, on-demand wake ~10:00+), so this job had NEVER been running.
  # repeat_missed also covers Sundays that start after 15:00.
  schedule      = "sun 15:00"
  repeat_missed = true
  storage       = "backups"
  vmid          = ["130"]
  enabled       = true
  compress      = "zstd"
  bwlimit       = 30720
  zstd          = 1
  mode          = "snapshot"
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
