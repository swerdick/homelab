# CT 117 — anduril (gaming LXC)

Privileged LXC that boots straight into **Steam Big Picture** on the living-room
TV, sharing the host's **AMD RX 9070 XT** via `amdgpu` (no GPU passthrough).
Replaced the GTX-970 passthrough VM (deleted 2026-06); same ID + name.

- **Shell:** `kwin_wayland` (Wayland) hosting `steam -gamepadui`, autostarted by
  `anduril-session.service`. gamescope can't get a seat in a VT-less LXC; KWin
  tolerates it. The Plasma *desktop pointer* is unusable (libinput needs a VT),
  so the controller drives Steam directly (`/dev/input` + `/dev/hidraw`).
- **GPU is shared, not claimed** — a future k3s AI-worker LXC can bind the same
  `renderD129` + `/dev/kfd`. See [[project-anduril-lxc-spike]].
- **Games:** `/games` = bind-mount of ZFS dataset `scratch/anduril-games` (WD
  Blue HDD, 600G quota, no backup — re-downloadable).
- **Audio:** `/dev/snd` passthrough -> PipeWire -> AMD HDMI sink (the TV).
- **Admin:** SSH; xrdp+XFCE for a mouse/keyboard desktop (Prism, emulators).

## Config split (bpg can't express these -> ansible-managed on the host)
Raw `lxc.*` device passthrough (`/dev/dri/card0`+`renderD129`, `/dev/kfd`,
`/dev/input`, `/dev/uinput`, `/dev/hidraw*`, `/dev/snd`), `lxc.mount.auto: sys:rw`,
and the `features` flags all live in `/etc/pve/lxc/117.conf` via
`setup-anduril-lxc.yaml` (privileged-CT features/binds are root@pam-only, so the
TF token can't set them — this CT was `pct create`d + imported, like the others).
Host `amdgpu`/fbcon/`hid-steam` prereqs: `setup-amdgpu-host.yaml`. In-guest
session: `setup-anduril-session.yaml`.
