# tirion — CT 141, unprivileged step-ca container (internal CA).
# Minimal: no bind mounts, no description, 1 core / 512MB / 4GB.

resource "proxmox_virtual_environment_container" "tirion" {
  node_name    = "earendil"
  unprivileged = true

  start_on_boot = true
  started       = true

  disk {
    datastore_id = "local-zfs"
    size         = 4
  }

  features {
    nesting = true
  }

  memory {
    dedicated = 512
    swap      = 512
  }

  initialization {
    hostname = "tirion"
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
    mac_address = "BC:24:11:49:A0:AB"
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
