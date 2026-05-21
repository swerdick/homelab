# gondor — VM 140, Debian k3s server (the cluster's control plane).
# Cloned originally from the debian13-cloudinit template; disk is now
# independent (vm-140-disk-1, no template reference). PBS handles DR;
# TF here is for drift detection + matching the LXC pattern.

resource "proxmox_virtual_environment_vm" "gondor" {
  node_name = "earendil"
  name      = "gondor"

  bios          = "ovmf"
  machine       = "q35"
  scsi_hardware = "virtio-scsi-single"
  boot_order    = ["scsi0"]
  on_boot       = true
  started       = true

  agent {
    enabled = true
  }

  cpu {
    cores   = 6
    sockets = 1
    type    = "host"
  }

  memory {
    dedicated = 10240
    # `balloon: 0` in PVE config translates to floating = 0 (no ballooning).
    floating = 0
  }

  disk {
    datastore_id = "local-zfs"
    interface    = "scsi0"
    size         = 80
    discard      = "on"
    iothread     = true
    ssd          = true
  }

  efi_disk {
    datastore_id      = "local-zfs"
    type              = "4m"
    pre_enrolled_keys = true
  }

  initialization {
    datastore_id = "local-zfs"
    interface    = "ide2"
    upgrade      = true

    dns {
      domain = "vingilot.internal"
    }

    ip_config {
      ipv4 {
        address = "dhcp"
      }
    }

    user_account {
      username = "pseudo"
      keys     = ["ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIKrx8f5ZTO70pdIVDkyc4axBJ49597s/xH0tTH278Wk4 stephen.werdick@gmail.com"]
    }
  }

  network_device {
    bridge      = "vmbr0"
    model       = "virtio"
    mac_address = "BC:24:11:7E:B1:EE"
  }

  operating_system {
    type = "l26"
  }

  serial_device {
    device = "socket"
  }

  vga {
    type   = "serial0"
    memory = 16
  }

  startup {
    order      = 1
    down_delay = -1
    up_delay   = -1
  }

  lifecycle {
    ignore_changes = [
      # VM-specific timeout attrs — TF-side wait knobs, not PVE state.
      timeout_clone,
      timeout_create,
      timeout_migrate,
      timeout_reboot,
      timeout_shutdown_vm,
      timeout_start_vm,
      timeout_stop_vm,
      # mac_addresses is bpg's QEMU-guest-agent readout of EVERY NIC in the
      # guest — for gondor that includes 30+ k3s CNI/flannel/veth interfaces
      # that come and go with pod scheduling. Not config; ignore.
      mac_addresses,
      # bpg's import reads these as empty strings from PVE but its schema
      # has non-empty defaults — same null→default pattern as the container
      # timeouts. Ignoring rather than fighting bpg's schema quirks.
      keyboard_layout,
      agent[0].type,
      operating_system[0].type,
    ]
  }
}
