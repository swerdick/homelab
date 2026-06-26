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
    cores        = 8
    # Below default (100): anduril may burst to all 8 host threads (Fossilize
    # shader compiles parallelize across them), but yields to the infra guests
    # (gondor k3s VM, nfs, smb) under contention. cores is a ceiling, not a
    # reservation, so 8 just uses otherwise-idle threads on this 4c/8t host.
    units = 50
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

  # Shared emulation + game library on the bulk pool (ZFS `bulk/games`, group
  # `shares`/GID 10000), bind-mounted at the same path host/nfs/smb use so the
  # ROM/BIOS/save tree (/bulk/games/Emulation/...) survives a CT rebuild. Privileged
  # CT = 1:1 GID map, so the session user just joins `shares`
  # (install-anduril-emulators.yaml); no idmap.
  #
  # HOST-MANAGED, not applied by TF: bpg marks a mount_point `volume` as ForceNew,
  # so adding this to the *existing* CT plans a destroy/recreate (would wipe the
  # rootfs — though bind-mounted datasets like the Steam games survive). Like the
  # device passthrough + features, the bind mount is created host-side as `mp1` in
  # setup-anduril-lxc.yaml, and TF ignores mount_point (lifecycle below). This block
  # stays as desired-state documentation — what a fresh `pct create` would get. The
  # Steam-games mp0 above is likewise host-created + imported, not TF-applied.
  mount_point {
    volume = "/bulk/games"
    path   = "/bulk/games"
    shared = true
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
      # mount_point: bpg ForceNew on `volume` would destroy/recreate the CT to add
      # a bind mount (and privileged-CT mounts are root@pam-only anyway). Bind
      # mounts are created host-side (mp0/mp1 in setup-anduril-lxc.yaml); TF ignores
      # them so a new mount never plans a rebuild.
      mount_point,
    ]
  }
}
