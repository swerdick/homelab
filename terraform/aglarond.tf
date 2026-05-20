# aglarond — CT 131, unprivileged LXC shipping restic backups to Backblaze B2.
# Live container config + extensive description imported from earendil/pve-configs/lxc/131.conf.
# Description block carries operator docs (backup schedules, restic commands,
# recovery steps) — visible in PVE web UI.

resource "proxmox_virtual_environment_container" "aglarond" {
  node_name    = "earendil"
  # vm_id intentionally omitted — derived from the import ID. Setting it
  # in config alongside an import block doesn't suppress the state-fill diff.
  unprivileged = true

  # Long-form operator runbook (backup schedules, restic commands, recovery
  # steps) lives in a sidecar markdown file so the resource definition stays
  # scannable. Edit descriptions/aglarond.md to update what shows in PVE's
  # Notes tab; tofu apply syncs it.
  description = file("${path.module}/descriptions/aglarond.md")

  cpu {
    architecture = "amd64"
    cores        = 2
  }

  memory {
    dedicated = 1024
    swap      = 512
  }

  disk {
    datastore_id = "local-zfs"
    size         = 4
  }

  features {
    nesting = true
  }

  initialization {
    hostname = "aglarond"
    dns {
      domain = "vingilot.internal"
    }
    ip_config {
      ipv4 {
        address = "dhcp"
      }
    }
  }

  network_interface {
    bridge      = "vmbr0"
    name        = "eth0"
    firewall    = true
    mac_address = "BC:24:11:BF:68:49"
  }

  operating_system {
    type = "debian"
    # template_file_id is required by the bpg schema, but only matters at
    # initial container creation. Existing imports leave it as an empty
    # string — only set this when (re-)creating a container from scratch.
    template_file_id = ""
  }

  console {
    enabled   = true
    tty_count = 2
    type      = "tty"
  }

  start_on_boot = true
  started       = true

  # bpg's import leaves timeout_* attrs as null in state; without this
  # block, the first apply tries to "fix" the null→default delta and PVE
  # rejects the empty-body PUT with HTTP 500. These are TF-side wait knobs
  # — never stored on PVE — so ignoring drift on them is safe.
  lifecycle {
    ignore_changes = [
      timeout_clone,
      timeout_create,
      timeout_delete,
      timeout_start,
      timeout_update,
    ]
  }

  # Bind mounts mp0–mp7 (order matches the live container's PVE config).
  mount_point {
    volume    = "/bulk/pbs"
    path      = "/srv/pbs"
    read_only = true
  }
  mount_point {
    volume    = "/scratch/backups"
    path      = "/srv/scratch-backups"
    read_only = true
  }
  mount_point {
    volume    = "/etc"
    path      = "/srv/host-etc"
    read_only = true
  }
  mount_point {
    volume = "/bulk/restic-cache"
    path   = "/var/cache/restic"
  }
  mount_point {
    volume    = "/bulk/documents"
    path      = "/srv/documents"
    read_only = true
  }
  mount_point {
    volume    = "/bulk/media/music"
    path      = "/srv/music"
    read_only = true
  }
  mount_point {
    volume    = "/bulk/photos"
    path      = "/srv/photos"
    read_only = true
  }
  mount_point {
    volume    = "/bulk/media/wallpaper"
    path      = "/srv/wallpaper"
    read_only = true
  }
}
