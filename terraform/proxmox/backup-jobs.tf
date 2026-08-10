# Datacenter-level backup jobs (vzdump entries in /etc/pve/jobs.cfg).
#
# Four jobs total: two enabled (the active backup rotation), two disabled
# (legacy, imported with enabled=false to match reality; delete via PVE UI
# once the 2026-08 PBS cutover is validated — legacy_all_to_pbs is fully
# superseded by nightly_guests targeting `main`).
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
  # PBS on erebor (cutover 2026-08-09; previously zstd tarballs on the
  # `backups` dir storage). Deduped + incremental: CTs skip unchanged files
  # via metadata change detection, the gondor VM uses dirty bitmaps — after
  # the first full pass, nightly reads shrink from every-guest-in-full to
  # the changed blocks. Offsite stays aglarond restic, which already ships
  # /bulk/pbs to B2. Old tarballs stay on /scratch (+ 30d in B2) as the
  # fallback until a validated PBS restore closes the migration.
  storage = "main"
  vmid    = ["117", "120", "121", "131", "140", "141", "142"]
  enabled = true
  # 30 MiB/s read cap (KiB/s) so the first full pass and repeat-missed
  # catch-up runs stay gentle even when they collide with an interactive
  # session. No compress/zstd attrs: PBS does its own zstd chunk
  # compression. ionice omitted: no-op on ZFS-backed sources.
  bwlimit                   = 30720
  pbs_change_detection_mode = "metadata"
  mode                      = "snapshot"
  notes_template            = "{{guestname}}"
  # The old 7d/4w/6m policy blew the 300G dir-storage quota (full-size
  # tarballs); PBS dedup makes it affordable again.
  prune_backups = {
    keep-daily   = "7"
    keep-weekly  = "4"
    keep-monthly = "6"
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
  schedule       = "sun 15:00"
  repeat_missed  = true
  storage        = "backups"
  vmid           = ["130"]
  enabled        = true
  compress       = "zstd"
  bwlimit        = 30720
  zstd           = 1
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
