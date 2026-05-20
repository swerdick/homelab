# erebor — CT 130, unprivileged LXC running Proxmox Backup Server.
# Single bind mount: host /bulk/pbs -> /datastore (PBS chunk store).

resource "proxmox_virtual_environment_container" "erebor" {
  node_name    = "earendil"
  unprivileged = true

  description = file("${path.module}/descriptions/erebor.md")

  start_on_boot = true
  started       = true

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
    size         = 16
  }

  features {
    nesting = true
  }

  initialization {
    hostname = "erebor"
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
    mac_address = "BC:24:11:B2:CF:BD"
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

  mount_point {
    volume = "/bulk/pbs"
    path   = "/datastore"
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
