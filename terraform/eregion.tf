# eregion — CT 142, unprivileged Paper Minecraft server.
# Second Age realm of the elven-smiths; thematic fit for a crafting server.
# In-guest config: ansible/playbooks/install-paper-mc.yaml.

resource "proxmox_virtual_environment_container" "eregion" {
  vm_id        = 142
  node_name    = "earendil"
  unprivileged = true

  start_on_boot = true
  started       = true

  disk {
    datastore_id = "local-zfs"
    size         = 20
  }

  features {
    nesting = true
  }

  cpu {
    cores = 2
  }

  memory {
    dedicated = 4096
    swap      = 512
  }

  initialization {
    hostname = "eregion"
    dns {
      domain = "vingilot.internal"
    }
    # Static IP rather than DHCP — IPs are already pinned in router DNS (and
    # will be in pihole/adguard TF later), so the LXC's TF is the natural
    # source of truth. Eliminates the router-side DHCP-reservation step.
    # First eregion-only; backfill the other LXCs in a fleet-wide sweep.
    ip_config {
      ipv4 {
        address = "192.168.1.42/24"
        gateway = "192.168.1.1"
      }
    }
  }

  network_interface {
    bridge      = "vmbr0"
    name        = "eth0"
    firewall    = true
    mac_address = "BC:24:11:E2:91:42"
  }

  operating_system {
    type             = "debian"
    template_file_id = "local:vztmpl/debian-13-standard_13.1-2_amd64.tar.zst"
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
