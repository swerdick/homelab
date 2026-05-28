# smb — CT 121, unprivileged LXC serving macOS via SMB3.
# Custom idmap maps guest GID 10000 -> host GID 10000 so the `shares` group
# works across the unprivileged boundary (see descriptions/smb.md for full
# rationale). bpg requires SSH access to *modify* idmap blocks; reading on
# import works fine over the API.

resource "proxmox_virtual_environment_container" "smb" {
  node_name    = "earendil"
  unprivileged = true

  description = file("${path.module}/descriptions/smb.md")

  start_on_boot = true
  started       = true

  cpu {
    architecture = "amd64"
    cores        = 2
  }

  memory {
    dedicated = 512
    swap      = 512
  }

  disk {
    datastore_id = "local-zfs"
    size         = 8
  }

  features {
    nesting = true
  }

  # Maps containers UIDs/GIDs back to specific host UIDs/GIDs. The g 10000
  # -> 10000 line is what lets smbuser inside the container access bulk/*
  # datasets owned by host GID 10000 (`shares`).
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
    hostname = "smb"
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
    firewall    = false
    mac_address = "BC:24:11:5C:16:39"
  }

  operating_system {
    type             = "debian"
    template_file_id = ""
  }

  console {
    enabled   = true
    tty_count = 2
    type      = "tty"
  }

  # Bind mounts mp0..mp5 (order matches live PVE config).
  mount_point {
    volume    = "/mnt/rescued"
    path      = "/srv/rescued"
    read_only = true
  }
  mount_point {
    volume = "/bulk/documents"
    path   = "/bulk/documents"
    shared = true
  }
  mount_point {
    volume = "/bulk/downloads"
    path   = "/bulk/downloads"
    shared = true
  }
  mount_point {
    volume = "/bulk/games"
    path   = "/bulk/games"
    shared = true
  }
  mount_point {
    volume = "/bulk/media"
    path   = "/bulk/media"
    shared = true
  }
  mount_point {
    volume = "/bulk/photos"
    path   = "/bulk/photos"
    shared = true
  }

  startup {
    order      = 5
    down_delay = -1
    up_delay   = -1
  }

  lifecycle {
    ignore_changes = [
      timeout_clone,
      timeout_create,
      timeout_delete,
      timeout_start,
      timeout_update,
    ]
  }
}
