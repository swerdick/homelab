# anduril — CT 117, PRIVILEGED LXC: the amdgpu-sharing gaming box (Steam Big
# Picture on the TV via KWin, sharing the AMD RX 9070 XT). Replaced the
# GPU-passthrough VM (deleted 2026-06); same ID + name. See descriptions/anduril.md.
#
# Created with `pct` and IMPORTED (privileged-CT feature flags + bind mounts are
# root@pam-only via API token — HTTP 403 — same reason the other containers were
# created-then-imported). Raw lxc.* device passthrough, `lxc.mount.auto: sys:rw`,
# and `features` are managed host-side by ansible (setup-anduril-lxc.yaml) against
# /etc/pve/lxc/117.conf; `features` is in ignore_changes so bpg won't fight it.
# Host amdgpu prereqs: setup-amdgpu-host.yaml. Findings: [[project-anduril-lxc-spike]].

resource "proxmox_virtual_environment_container" "anduril" {
  node_name    = "earendil"
  vm_id        = 117
  unprivileged = false

  description = file("${path.module}/descriptions/anduril.md")

  start_on_boot = true
  started       = true

  cpu {
    architecture = "amd64"
    cores        = 6
  }

  memory {
    dedicated = 12288
    swap      = 2048
  }

  disk {
    datastore_id = "local-zfs"
    size         = 64
  }

  initialization {
    hostname = "anduril"
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
    mac_address = "BC:24:11:2B:A8:D6"
  }

  operating_system {
    type             = "ubuntu"
    template_file_id = ""
  }

  console {
    enabled   = true
    tty_count = 2
    type      = "tty"
  }

  # Steam library on the scratch pool (WD Blue HDD; re-downloadable, no backup).
  mount_point {
    volume = "/scratch/anduril-games"
    path   = "/games"
    backup = false
  }

  startup {
    order      = 10
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
      # features (nesting/keyctl) are set host-side by ansible — root@pam-only
      # on a privileged CT, so the TF token can't manage them.
      features,
    ]
  }
}
