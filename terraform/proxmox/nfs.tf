# nfs — CT 120, PRIVILEGED LXC running kernel NFSv4 server.
# Privileged because kernel NFSd needs capabilities the unprivileged set
# doesn't grant. `features.mount = ["nfs"]` enables the NFS feature for
# the *server*; the "SMB/CIFS" feature is for client mounts (not used).

resource "proxmox_virtual_environment_container" "nfs" {
  node_name    = "earendil"
  unprivileged = false

  description = file("${path.module}/descriptions/nfs.md")

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
    size         = 8
  }

  features {
    nesting = true
    mount   = ["nfs"]
  }

  initialization {
    hostname = "nfs"
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
    mac_address = "BC:24:11:0D:61:E9"
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

  # Bind mounts mp1..mp6 — note: live config has no mp0 (gap intentional;
  # mp0 slot reserved historically). Each /bulk/* dataset is bound to the
  # same path inside the guest with `shared=true`.
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
  mount_point {
    volume = "/scratch/k3s-pvs"
    path   = "/scratch/k3s-pvs"
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
