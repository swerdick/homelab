# mirdain — CT 143, PRIVILEGED LXC: the GPU-worker k3s agent (the AI/ROCm half
# of the amdgpu-sharing design — ROADMAP "Anduril Phase 2"), sharing the AMD
# RX 9070 XT with the anduril gaming CT. See descriptions/mirdain.md.
#
# Created with `pct` and IMPORTED (privileged-CT feature flags + bind mounts are
# root@pam-only via API token — HTTP 403 — same reason the other containers were
# created-then-imported). Raw lxc.* lines (GPU devices + the k3s-in-LXC set:
# kmsg/tun/proc:rw sys:rw/apparmor-unconfined/cleared cap.drop), `features`, and
# the mpN binds are managed host-side by ansible (setup-mirdain-lxc.yaml)
# against /etc/pve/lxc/143.conf; `features`/`mount_point` are in ignore_changes
# so bpg won't fight them. Host amdgpu prereqs: setup-amdgpu-host.yaml.

resource "proxmox_virtual_environment_container" "mirdain" {
  node_name    = "earendil"
  vm_id        = 143
  unprivileged = false

  description = file("${path.module}/descriptions/mirdain.md")

  start_on_boot = true
  started       = true

  cpu {
    architecture = "amd64"
    # 4 cores, not 8: GPU inference is GPU-bound (CPU is VAE decode and
    # tokenization), and 4 caps worst-case scheduler pressure on the 4c/8t
    # host — gondor already claims 6 and anduril 8. units below default (100)
    # matches anduril's rationale: a ceiling that yields to the infra guests
    # under contention.
    cores = 4
    units = 50
  }

  memory {
    dedicated = 16384
    # swap 0 is deliberate (kubelet-correct): with CT swap, memory pressure
    # silently pages model weights out to host swap on the rpool SSD; with 0
    # it fails loud as an OOM-kill inside mirdain's own cgroup.
    swap = 0
  }

  disk {
    datastore_id = "local-zfs"
    # OS + k3s state only — the containerd image store lives on the
    # scratch/mirdain-k3s dataset (mp0), off the ~fully-committed rpool SSD.
    size = 24
  }

  initialization {
    hostname = "mirdain"
    dns {
      domain = "vingilot.internal"
    }
    # Static, like eregion (the ROADMAP fresh-LXC-bootstrap convention):
    # ansible + the k3s join reach the node by name/IP before DHCP
    # reservations exist.
    ip_config {
      ipv4 {
        address = "192.168.1.43/24"
        gateway = "192.168.1.1"
      }
    }
  }

  network_interface {
    bridge      = "vmbr0"
    name        = "eth0"
    firewall    = false
    mac_address = "BC:24:11:42:9B:E7"
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

  # containerd image store on the scratch pool (re-downloadable image layers;
  # no backup). HOST-MANAGED, not applied by TF: bpg marks a mount_point
  # `volume` as ForceNew, so adding one to the existing CT would plan a
  # destroy/recreate (and privileged-CT mounts are root@pam-only anyway). The
  # bind is created host-side as mp0 in setup-mirdain-lxc.yaml; TF ignores
  # mount_point (lifecycle below). This block is desired-state documentation —
  # what a fresh `pct create` would get.
  mount_point {
    volume = "/scratch/mirdain-k3s"
    path   = "/var/lib/rancher"
    backup = false
  }

  # Model weights + generation outputs on the bulk pool (2770 root:10000, so
  # the existing smb `bulk` share exposes them to the Mac). HOST-MANAGED mp1 —
  # same documentation-only status as mp0.
  mount_point {
    volume = "/bulk/ai-models"
    path   = "/bulk/ai-models"
    shared = true
    backup = false
  }

  startup {
    order      = 30
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
      # mount_point: bpg ForceNew on `volume` would destroy/recreate the CT to
      # add a bind mount (and privileged-CT mounts are root@pam-only anyway).
      # Bind mounts are created host-side (mp0/mp1 in setup-mirdain-lxc.yaml);
      # TF ignores them so a new mount never plans a rebuild.
      mount_point,
    ]
  }
}
