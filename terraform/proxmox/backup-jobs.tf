# Datacenter-level backup jobs (vzdump entries in /etc/pve/jobs.cfg).
#
# Two jobs: the nightly guest rotation to PBS and erebor's weekly config
# tarball. The two disabled legacy tarball-era jobs were deleted when the
# 2026-08 PBS cutover was validated (restore test 2026-08-12).
#
# Job IDs are PVE-generated UUIDs (backup-<8hex>-<4hex>). Not pretty but
# changing them would require destroy+create — TF resource names
# (nightly_guests etc.) are the human-readable handle.

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
  # PBS on erebor (cutover 2026-08-09; restore-validated and tarball era
  # cleaned up 2026-08-12). Deduped + incremental: CTs skip unchanged
  # files via metadata change detection. The gondor VM would use dirty
  # bitmaps, but they don't survive the nightly power cycle, so it
  # full-reads its 80G disk each run under the bwlimit (~45 min,
  # tolerable in this window — see the ROADMAP oddities entry). Offsite
  # stays aglarond restic, which ships /bulk/pbs to B2.
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
