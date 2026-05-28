# VM 117 — Kubuntu (anduril)

KVM guest running Kubuntu 26.04 LTS (Plasma 6) for game streaming via Sunshine + Moonlight. Theme: the reforged gaming PC, like Andúril reforged from Narsil's shards. Replatformed from Bazzite to Kubuntu in May 2026 — Bazzite dropped Sunshine from its base image (F44+), and on an atomic distro that's an unfixable structural mismatch; a traditional distro lets us `apt install`/pin Sunshine and the NVIDIA driver directly.

## VM config

- **VMID:** 117 · **Name:** `anduril` (`anduril.vingilot.internal`)
- **OS:** Kubuntu 26.04 LTS (Plasma 6, Wayland) · NVIDIA proprietary **580** branch
- **Hardware:** 6 cores `cpu=host`, 10 GiB RAM (no ballooning)
- **Firmware:** q35 + OVMF UEFI
- **Disk:** 128 GiB on `local-zfs`, virtio-scsi-single with discard + iothread + SSD emulation
- **Network:** static IP 192.168.1.17 via router DHCP reservation (MAC `BC:24:11:2B:A8:D6`)

Config + OS-level setup live in `ansible/playbooks/site-anduril.yaml` (pseudo user, Debian base, root CA, unattended-upgrades, Alloy, Sunshine) and `ansible/host_vars/anduril/`.

## NVIDIA driver + kernel — two load-bearing pins (manual bring-up)

The GTX 970 is **Maxwell (GM204)**; the **580** branch is the *last* NVIDIA driver to support it (590/595 drop it and the card won't init). But the obvious `apt install nvidia-driver-580` **does not work here** — see the `project-anduril-kubuntu-nvenc-recipe` memory for the full debugging story. Two non-obvious pins:

- **Driver: 580.95.05 from the `.run` installer, NOT apt.** Apt's `nvidia-driver-580` (=580.159.03) hangs the display engine (Xid 56/62, flip-event timeout). Bazzite's proven 580.95.05 via `sudo ./NVIDIA-Linux-x86_64-580.95.05.run --silent --dkms --no-x-check` is the working build. (Gotchas: purge `nvidia-*`/`libnvidia-*` + reboot so nouveau-disable takes; install `pkg-config` + `libglvnd-dev` first or it skips the EGL vendor config.)
- **Kernel: mainline 6.12.90, NOT Kubuntu's stock 7.0.** On 7.0 the 580 DRM modeset path wedges `kwin_wayland` in `nv_drm_atomic_commit`. Installed from kernel.ubuntu.com/mainline `.deb`s and pinned GRUB default (`GRUB_DEFAULT=saved` + `grub-set-default` the 6.12.90 entry).

Both are a **manual bring-up — too fragile to automate** — captured in the PBS snapshot; recovery is restore-snapshot + re-run `site-anduril.yaml`, not a fresh build. Hold the stock kernel so apt can't pull a 7.0 over it:

```
sudo apt-mark hold linux-image-generic linux-headers-generic linux-generic
```

`linux-`/`nvidia-` are also blacklisted from unattended-upgrades via `host_vars/anduril`. **Never run a blind `apt upgrade`** until those holds are in place — a stock-kernel bump breaks the pinned combo. The boot cmdline this needs (`nvidia-drm.modeset=1 initcall_blacklist=simpledrm_platform_driver_init`) and the nouveau blacklist are codified in `setup-sunshine.yaml`.

## GPU passthrough

Full-card passthrough of host GTX 970:

```
hostpci0: 0000:01:00,pcie=1,x-vga=1
```

Host-side prerequisites (kernel cmdline, vfio modules, NVIDIA blacklist, vfio.conf bind, kernel pin) are managed on earendil by `ansible/playbooks/setup-vfio-passthrough.yaml` + `pin-proxmox-kernel.yaml` — untouched by the guest OS, so they survived the replatform.

## USB passthrough

None configured (not in Terraform). Headless streaming needs no physical peripherals — Sunshine injects keyboard/mouse/gamepad via uinput. A future Steam Controller 2 2.4 GHz dongle would be added best-effort with `usbN: host=VID:PID` (warns but doesn't block boot if absent); never make a USB device boot-mandatory.

## Sunshine — installed from LizardByte's .deb

There's no apt repo; Sunshine is installed from the per-release `.deb` (`sunshine-ubuntu-26.04-amd64.deb`), version-pinned in `host_vars/anduril/main.yaml` and applied by `setup-sunshine.yaml`. That playbook also:

- enables the user unit (`app-dev.lizardbyte.app.Sunshine.service`) + linger on `pseudo`,
- sets `cap_sys_admin+p` on `/usr/bin/sunshine` for KMS frame capture and adds `pseudo` to `input`,
- autologins `pseudo` into the Plasma Wayland session via SDDM (a live session is required for capture on a headless host),
- replaces the unit's `sleep 5` startup with a poll for `WAYLAND_DISPLAY` (avoids the empty-environ busy-loop that wedges the nvidia driver),
- whitelists the host FQDN in `csrf_allowed_origins` so the web UI (`https://anduril.vingilot.internal:47990`) can be paired from a laptop,
- and enables `nvidia-persistenced` so NVENC isn't lost to a cold CUDA init.

A persistent **kde-inhibit** user service (`sunshine-keepawake.service`) holds a power+screensaver inhibit so the display **never** blanks — on this card a DPMS-off/wake cycle corrupts KMS capture until a host reboot. (Plasma 6.6's own powerdevil `idleTime` config proved unreliable; the inhibitor is verified to hold the display On past a blank timeout.) The screen lock is disabled via `kscreenlockerrc`.

## Moonlight tuning (Maxwell NVENC)

GTX 970 is 2nd-gen NVENC. Constraints:

- Force **H.264** in Moonlight client. HEVC is glitchy, AV1 unsupported, 10-bit rejected. The probe errors in Sunshine logs are noise.
- LAN sweet spot: **1080p60 + 30–50 Mbps**. Native-res streaming chokes the encoder.
- Enable Moonlight's **"Optimize mouse for remote desktop"** (absolute positioning) and **"Frame pacing"** for desktop use.

## Headless operation

HDMI dummy plug installed (Woieyeks EDID 3-pack, Apr 2026). Without it, a monitor must be physically connected and powered for streaming to initialize the display pipeline.

## Backup

Included in the nightly local backup job (`proxmox_backup_job.nightly_guests` in `terraform/backup-jobs.tf`, schedule `21:00`, target storage **`backups`** = local vzdump on earendil's `/scratch` pool, zstd, keep 7d/4w/6m). Recovery: restore VM 117 from the latest snapshot, then re-run `site-anduril.yaml`. Take a fresh snapshot after any validated bring-up.

## Troubleshooting

**Black screen after VM start:** check `dmesg` on host for vfio reset issues. GTX 970 occasionally needs the VM stopped (not paused) and started fresh after a host reboot before passthrough initializes cleanly.

**Sunshine wedged / `Couldn't find monitor` while the display reads `dpms On`:** the GPU's KMS-capture/NVENC state is corrupt. A `qm stop`/`start` does **not** fix it — the GTX 970 has no PCI reset (`error writing '1' to .../reset: Inappropriate ioctl`), so the bad state survives the VM restart: driver + display come back looking fine, but NVENC stays broken (`doesn't support required NVENC features` / `Failed locking bitstream buffer`) and Sunshine hangs after its banner without opening its ports. **Only a host reboot of earendil reliably resets the card.** Trigger to avoid: never hot-change the display mode/refresh on a live session (`kscreen-doctor` modeset) — that is what wedges it.

**`nvidia-smi` shows wrong/no driver:** confirm the **580** branch is installed and held (not 595, which drops Maxwell). See the NVIDIA section above.

**Sunshine not finding display:** HDMI source not active (dummy plug absent) **or** no graphical session — confirm SDDM autologged `pseudo` into Plasma (`loginctl` shows an active Wayland seat).

**Moonlight encoder errors in Sunshine logs about HEVC/AV1/10-bit:** noise. Force H.264 client-side.

**Won't boot / out of memory on host:** earendil shares RAM between anduril (10 GiB pinned) and eregion (CT 142) until the RAM upgrade — stop eregion (`pct stop 142`) before starting anduril.
