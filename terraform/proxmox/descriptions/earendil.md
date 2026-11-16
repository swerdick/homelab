# Host configuration — earendil

> Snapshot of the earendil node Notes panel (`/etc/pve/nodes/earendil/config`),
> copied 2026-11-15 so it exists outside the host. Unlike the guest
> descriptions here, nothing applies this file back to PVE. Several sections
> predate the 2026-06 GPU swap and the PBS/restic backup rework; `AGENTS.md`
> is the current hardware reference.

## Hardware
- CPU: Intel i7-6700K (Skylake, iGPU: HD 530)
- Board: MSI Z170A Gaming M7, BIOS 1.L0
- GPU: NVIDIA GTX 970 (Maxwell) — passed through to VM 117 (anduril)
- RAM: 2×8GB DDR4-3000 CL15 (2 slots free)
- PSU: EVGA SuperNOVA 750 G2 (ECO mode on)
- Boot drive: Samsung 850 EVO 250GB

## BIOS settings
VT-d: on · IGD primary: yes · CFG Lock: off · C1E: on · XMP: off · WoL: on · Game Boost: off

## Storage layout

| Pool | Drive | Purpose |
|---|---|---|
| `rpool` | 850 EVO 250GB | Boot + VM/CT root disks (`local`, `local-zfs`) |
| `scratch` | WD Blue 1TB | `/scratch/backups` (PBS-config vzdump), `/scratch/restore` (old PC data, pending reorg) |
| `bulk` | FireCuda 2TB SSHD | `/bulk/{archive,documents,downloads,games,media,photos}` (shared via 120/121), `/bulk/pbs` (PBS datastore for CT 130) |

Each `/bulk/*` is a separate ZFS dataset. Bind mounts into LXCs must be per-dataset; a single `/bulk` mount only exposes the parent's placeholder directories.

## Shared group (host-side)

`shares` group, GID 10000. Datasets under `/bulk/*` are chgrp'd to it with setgid bit on directories so new files inherit the group. CT 121 (smb) uses an idmap to translate this; CT 120 (nfs) is privileged so it sees GID 10000 1:1 with the host. See respective CT notes.

```
groupadd -g 10000 shares
chown -R root:shares /bulk/{documents,downloads,games,media,photos,archive}
find /bulk/{documents,downloads,games,media,photos,archive} \
  -type d -exec chmod 2775 {} +
find /bulk/{documents,downloads,games,media,photos,archive} \
  -type f -exec chmod 0664 {} +
```

`/etc/subgid` includes `root:10000:1` for CT 121's idmap.

## GPU passthrough configuration

Host uses Intel HD 530 iGPU; GTX 970 is bound to vfio-pci for VM 117.

### 1. Kernel cmdline — `/etc/kernel/cmdline`

Appended: `intel_iommu=on iommu=pt`

Apply with: `proxmox-boot-tool refresh`

### 2. VFIO modules — `/etc/modules`

```
vfio
vfio_iommu_type1
vfio_pci
```

(`vfio_virqfd` was folded into the main module in recent kernels — don't add it.)

### 3. NVIDIA host blacklist — `/etc/modprobe.d/blacklist-nvidia.conf`

```
blacklist nouveau
blacklist nvidia
blacklist nvidiafb
blacklist nvidia_drm
```

### 4. VFIO bind — `/etc/modprobe.d/vfio.conf`

```
options vfio-pci ids=10de:13c2,10de:0fbb disable_vga=1
```

GTX 970 VGA + HDMI audio functions.

### Verification after reboot

```
cat /proc/cmdline                         # kernel flags active
dmesg | grep -e DMAR -e IOMMU             # IOMMU initialized
lspci -nnk -s 01:00                       # "Kernel driver in use: vfio-pci"
```

### Teardown / reversal

Each layer reversible independently. Inner → outer:

**Unbind specific GPU (keep passthrough infra):**
`rm /etc/modprobe.d/vfio.conf && update-initramfs -u -k all && reboot`

**Remove NVIDIA blacklist:**
`rm /etc/modprobe.d/blacklist-nvidia.conf && update-initramfs -u -k all && reboot`

**Remove VFIO modules:** edit `/etc/modules`, remove vfio lines.
`update-initramfs -u -k all && reboot`

**Disable IOMMU:** edit `/etc/kernel/cmdline`, remove flags.
`proxmox-boot-tool refresh && reboot`

## Backup architecture

Two-LXC pipeline: **CT 130 (erebor)** runs PBS for guest backups locally; **CT 131 (aglarond, planned)** runs restic to ship critical data offsite to Backblaze B2. Host-side orchestrator at `/etc/systemd/system/nightly-backup.{service,timer}` runs vzdump → PBS → restic in order, with `Persistent=true` for catch-up after power-on.

PBS config protected by weekly host-level vzdump of CT 130 to `/scratch/backups` (datastore bind mount excluded automatically).

See per-CT notes for service-specific details.
