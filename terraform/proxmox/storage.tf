# Datacenter-level storage entries on earendil.
#
# Not managed here: `local` and `local-zfs` — both auto-created by the
# PVE installer (dir on /var/lib/vz + zfspool on rpool/data). A fresh
# install brings them up; TF would just be claiming ownership of
# installer-default resources for no gain. If we ever override their
# settings, add them then.
#
# Per ROADMAP item "Clarify earendil storage location naming": the
# names here are confusing (`main` for PBS, `backups` for local
# vzdump). Renaming is a separate effort because storage IDs are
# referenced by every guest disk pointer.

resource "proxmox_storage_directory" "backups" {
  id      = "backups"
  path    = "/scratch/backups"
  content = ["backup"]
  # bpg's schema default for `shared` on directory storage is true; live
  # PVE has false (this is a single-node "cluster" — sharing across nodes
  # isn't meaningful). Pin explicitly so plan stays a no-op.
  shared = false
}

resource "proxmox_storage_pbs" "main" {
  id        = "main"
  server    = "erebor.vingilot.internal"
  datastore = "main"
  username  = "root@pam!earendil-host"
  # Password (API token secret) lives in SOPS, not in storage.cfg —
  # PVE keeps it at /etc/pve/priv/storage/main.pw. The justfile `tf`
  # wrapper decrypts it from ansible/group_vars/all/secrets.sops.yaml
  # and exports as TF_VAR_pbs_main_password per-invocation. The variable
  # is required (bpg schema), but we ignore_changes because:
  #   - the import doesn't capture password from PVE (the API doesn't
  #     return it)
  #   - bpg marks password as ForceNew, so any config-vs-state mismatch
  #     would destroy+recreate the storage entry (disrupting backups)
  #   - PVE already has the right password; TF claiming ownership of
  #     it would just trip over that
  password = var.pbs_main_password
  content  = ["backup"]

  lifecycle {
    ignore_changes = [password]
  }
}

resource "proxmox_storage_zfspool" "scratch_zfs" {
  id             = "scratch-zfs"
  zfs_pool       = "scratch"
  content        = ["images", "rootdir"]
  blocksize      = "8k"
  thin_provision = true
}
