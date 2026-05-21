# VM 117 — Bazzite (anduril)

KVM guest running Bazzite KDE for game streaming via Sunshine + Moonlight. Theme: the reforged gaming PC, like Andúril reforged from Narsil's shards.

## VM config

- **VMID:** 117 · **Name:** `anduril` (`anduril.vingilot.internal`)
- **OS:** Bazzite KDE (legacy `-nvidia` image) · NVIDIA driver 580.95.05
- **Hardware:** 4 cores `cpu=host`, 10 GiB RAM (no ballooning)
- **Firmware:** q35 + OVMF UEFI
- **Disk:** 128 GiB on `local-zfs`, virtio-scsi-single with discard + iothread + SSD emulation
- **Network:** static IP 192.168.1.17 via router DHCP reservation

## GPU passthrough

Full-card passthrough of host GTX 970:

```
hostpci0: 0000:01:00,pcie=1,x-vga=1
```

Host-side prerequisites are documented in earendil host notes (kernel cmdline, vfio modules, NVIDIA blacklist, vfio.conf bind).

## USB passthrough

Pass through directly attached peripherals:

- Razer Basilisk V3 Pro: vendor:product `1532:00aa`
- Corsair K95 RGB Platinum: `1b1c:1b2d`

```
usb0: host=1532:00aa
usb1: host=1b1c:1b2d
```

## Sunshine — use the native systemd unit

**Don't run `ujust setup-sunshine`** — it installs the Homebrew sunshine under `/home/linuxbrew`, which dies in VM passthrough with `Couldn't import RGB Image: 00003009`.

The bazzite-nvidia image ships native `/usr/bin/sunshine` with a systemd user unit. Enable it directly:

```
systemctl --user enable --now app-dev.lizardbyte.app.Sunshine.service
```

`systemd --user` can't grant `AmbientCapabilities`, so the `CAP_SYS_NICE` warning persists in logs — cosmetic, ignore.

## Moonlight tuning (Maxwell NVENC)

GTX 970 is 2nd-gen NVENC. Constraints:

- Force **H.264** in Moonlight client. HEVC is glitchy, AV1 unsupported, 10-bit rejected. The probe errors in Sunshine logs are noise.
- LAN sweet spot: **1080p60 + 30–50 Mbps**. Native-res streaming chokes the encoder.
- Enable Moonlight's **"Optimize mouse for remote desktop"** (absolute positioning) and **"Frame pacing"** for desktop use.

## Headless operation

Requires HDMI dummy plug — currently pending. Without one, monitor must be physically connected and powered for streaming to initialize the display pipeline.

## Backup

Included in PBS backup job `guests-to-pbs` (CT 130 / erebor). PBS chunk-level dedup is significantly more space-efficient than vzdump for this VM — game installs and OS files dedupe heavily across nightly snapshots.

## Troubleshooting

**Black screen after VM start:** check `dmesg` on host for vfio reset issues. GTX 970 occasionally needs the VM stopped (not paused) and started fresh after host reboot before passthrough initializes cleanly.

**Sunshine not finding display:** HDMI source not active. With dummy plug absent, monitor must be powered on and on the right input.

**Moonlight encoder errors in Sunshine logs about HEVC/AV1/10-bit:** noise. Force H.264 client-side.

**USB device not appearing:** check the `1532:00aa`-style ID matches. Replug-and-check with `lsusb` on host before adjusting VM config.
