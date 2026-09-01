# aglarond — CT 131, unprivileged LXC shipping restic backups to Backblaze B2.
# Live container config + extensive description imported from earendil/pve-configs/lxc/131.conf.
# Description block carries operator docs (backup schedules, restic commands,
# recovery steps) — visible in PVE web UI.

resource "proxmox_virtual_environment_container" "aglarond" {
  node_name = "earendil"
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
    # Low cgroup cpu.weight (PVE default 100): restic chunking should always
    # yield to interactive guests under host contention. Work-conserving —
    # full speed on an idle host, near-zero share when anduril wants the
    # cores (backup-vs-gaming stutter, diagnosed 2026-08-09).
    units = 20
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

  # Custom idmap maps guest GID 10000 -> host GID 10000 for the `shares`
  # group (media access) — same pattern as smb.tf. The live lines are also
  # asserted by setup-aglarond.yaml; declaring them here keeps TF from
  # planning their removal after a refresh picks them up. bpg requires SSH
  # access to *modify* idmap blocks; matching config never touches them.
  idmap {
    container_id = 0
    host_id      = 100000
    size         = 65536
    type         = "uid"
  }
  idmap {
    container_id = 0
    host_id      = 100000
    size         = 10000
    type         = "gid"
  }
  idmap {
    container_id = 10000
    host_id      = 10000
    size         = 1
    type         = "gid"
  }
  idmap {
    container_id = 10001
    host_id      = 110001
    size         = 55535
    type         = "gid"
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
      # mount_point: bpg marks `volume` ForceNew, so a host-side mpN addition
      # (ansible-managed binds) plans a destroy/recreate of the whole CT.
      # This EXACT gap destroyed aglarond on 2026-09-01 (restored from PBS
      # within the hour) when mp8/mp9 were added for the ComfyUI backup
      # slice — the ignore existed on anduril/mirdain but was never
      # backported here. The mount_point blocks below are desired-state
      # documentation only.
      mount_point,
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
