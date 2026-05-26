# anduril — VM 117, Kubuntu 26.04 LTS gaming VM with full GPU passthrough.
#
# Host-side passthrough prereqs (IOMMU cmdline, vfio modules, NVIDIA
# blacklist, vfio-pci ID binding) are codified in
# ansible/playbooks/setup-vfio-passthrough.yaml. Without those landed
# on the host, this VM will hang on `RmInitAdapter failed!` at boot
# because the host kernel will have claimed the GPU first.
#
# USB passthrough is intentionally NOT defined here right now — the live
# PVE config has no usb0/usb1 lines after a recent manual removal. When
# the Razer/Corsair (or future Steam Controller 2 dongle) get re-attached,
# add `usb { ... }` blocks with `host = "VID:PID"`. Per project memory:
# USB passthrough must always be best-effort, never boot-mandatory — the
# VM must come up even if a dongle is unplugged.

resource "proxmox_virtual_environment_vm" "anduril" {
  node_name = "earendil"
  name      = "anduril"

  description = file("${path.module}/descriptions/anduril.md")

  bios          = "ovmf"
  machine       = "q35"
  scsi_hardware = "virtio-scsi-single"
  boot_order    = ["scsi0", "net0"]
  on_boot       = true
  started       = true

  # Never let Terraform power-cycle anduril. A bpg-issued graceful shutdown
  # hangs indefinitely here: the headless Plasma session intercepts the ACPI
  # power event (and the guest agent doesn't make it reliable), so an apply
  # that needs a reboot stalls and then risks escalating to a force-stop. A
  # hard stop is dangerous on this VM — the GTX 970 has no PCI reset, so a bad
  # re-init wedges NVENC until a *host* reboot of earendil (see anduril.md's
  # "Sunshine wedged" notes). With this false, an update that requires taking
  # the VM offline FAILS loudly instead; we then reboot anduril ourselves (PVE
  # UI / `qm reboot` / from inside) and re-apply. Learned the hard way on
  # 2026-05-24 while hot-adding the scsi1 games disk — bpg tried to reboot to
  # apply a cosmetic scsi0 option rewrite and the shutdown wedged.
  reboot_after_update = false

  agent {
    enabled = true
  }

  cpu {
    # 6 vCPUs on earendil's i7-6700K (4 cores / 8 threads): leaves 2 threads
    # for the host so the QEMU vhost-net + vfio backends that carry the
    # Moonlight stream aren't starved while the guest is busy (game + Sunshine
    # NVENC). Deliberately NOT all 8 — over-subscribing the host is where a
    # latency-sensitive stream goes choppy. Requires a VM stop/start to apply.
    cores   = 6
    sockets = 1
    type    = "host"
  }

  memory {
    dedicated = 12288
    # `balloon: 0` in PVE config → no ballooning, fixed 10 GiB.
    floating = 0
  }

  disk {
    datastore_id = "local-zfs"
    interface    = "scsi0"
    size         = 128
    discard      = "on"
    iothread     = true
    ssd          = true
  }

  # Game library on the WD Blue (scratch pool, ~658G free). Games are
  # re-downloadable, so this lives on the non-redundant scratch pool rather
  # than eating into bulk (kept free for media). Becomes zvol
  # scratch/vm-117-disk-N — a raw block device; anduril formats/mounts it
  # guest-side. Explicitly:
  #   ssd = false  — it's a 7200rpm HDD, don't lie to the guest about rotation.
  #   discard = on — TRIM passes through so deleting a game reclaims pool space
  #                  (scratch-zfs is thin-provisioned).
  #   backup = false — anduril is in the nightly vzdump (backup-jobs.tf:27),
  #                  which writes to /scratch/backups on this same disk. Backing
  #                  up a disposable 400G library to its own drive is pure waste
  #                  and would blow the backups quota.
  disk {
    datastore_id = "scratch-zfs"
    interface    = "scsi1"
    size         = 400
    discard      = "on"
    iothread     = true
    ssd          = false
    backup       = false
  }

  efi_disk {
    datastore_id      = "local-zfs"
    type              = "4m"
    pre_enrolled_keys = false
  }

  # GPU passthrough — host's GTX 970 (PCI 0000:01:00, both functions
  # via the bus-level ID). vfio-pci on the host (see setup-vfio-passthrough.yaml)
  # binds 10de:13c2 + 10de:0fbb so the kernel never touches the card and
  # KVM can hand it directly to this VM.
  hostpci {
    device = "hostpci0"
    id     = "0000:01:00"
    pcie   = true
    xvga   = true
    # rombar default in PVE is true (expose the device's option ROM via BAR).
    # bpg's import surfaces it explicitly; omitting from config would diff
    # toward null and the apply would clear it on the live VM.
    rombar = true
  }

  network_device {
    bridge      = "vmbr0"
    model       = "virtio"
    mac_address = "BC:24:11:2B:A8:D6"
    # firewall not enabled on anduril's net0 (matches live PVE config).
    firewall = false
  }

  operating_system {
    type = "l26"
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
      # mac_addresses is bpg's QEMU-guest-agent readout of every NIC the
      # guest reports. Volatile (changes when the VM stops/starts, when
      # the guest adds tap/veth/etc. interfaces). Not config.
      mac_addresses,
      # bpg's import reads these as empty strings from PVE but its schema
      # has non-empty defaults — same null→default state-fill pattern as
      # the container timeouts. Ignoring rather than fighting it.
      keyboard_layout,
      agent[0].type,
    ]
  }
}
