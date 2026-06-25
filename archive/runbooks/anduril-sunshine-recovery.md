# Anduril Sunshine Stream Recovery Runbook

> **Archived 2026-06-25.** Documents the NVIDIA GTX 970 / Sunshine-VM era of
> `anduril` (VM 117). That host has since been replatformed to an AMD 9070XT
> **LXC** (CT 117) with Sunshine running in-container — see
> `ansible/playbooks/setup-anduril-sunshine.yaml`. The NVIDIA-specific recovery
> below (`nvidia-smi`, NVENC, `Xid`) no longer applies to the live host; kept
> for reference.

Recovering Moonlight streaming to anduril (VM 117) when the stream won't start.
This is a recurring failure with a known root cause and a reliable — if blunt —
fix. The goal of this runbook is to get you from "it's broken" to "it's
streaming" in a few minutes without re-deriving the diagnosis every time.

## Symptom

- Moonlight discovers `anduril` and lists apps, but launching any app fails with
  **`Starting RTSP handshake failed: Error 60`** ("check your firewall and port
  forwarding rules for TCP 48010, UDP 48000, UDP 48010").
- Or: a stream was running, tore/glitched, and crashed; reconnects then fail.
- SSH to anduril and the PVE UI work fine — only the *stream* is dead.

It is **not** a firewall problem (anduril runs no host firewall) and **not** a
port-forwarding problem (this is all LAN). The Moonlight error text is
misleading — don't chase ports.

## Root cause

The GTX 970 is Maxwell and has **no PCIe function-level reset**
(`error writing '1' to .../reset: Inappropriate ioctl`). When a stream crashes —
especially after a display mode/refresh change — the card's CUDA/NVENC state
corrupts. The driver keeps working and `nvidia-smi` looks completely healthy,
but **CUDA can no longer initialize**, so Sunshine's NVENC encoder fails and it
silently falls back to the CPU `libx264` encoder, which can't sustain the
stream.

Because there is no PCIe reset, a `qm stop`/`start` of the VM **cannot** clear
it — the wedged state survives the VM restart. Only **removing power from the
card** (a full power-cycle of earendil) resets it, and a *warm* `reboot` is
sometimes not enough — a cold boot is.

Deep background: `terraform/descriptions/anduril.md` ("Sunshine wedged" and
"NVIDIA driver + kernel" sections).

## Fast diagnosis (~30 seconds)

From thorondor, one read-only block:

```bash
ssh anduril '
  echo "=== GPU: responsive? (a HANG itself means actively wedged) ==="
  timeout 15 nvidia-smi --query-gpu=name,driver_version,utilization.gpu --format=csv,noheader \
    || echo ">>> nvidia-smi HUNG = GPU wedged → Recovery A <<<"
  echo "=== GPU hardware faults (definitive) ==="
  sudo dmesg --ctime | grep -iE "NVRM: Xid|fallen off|nvidia.*error" | tail -10
  echo "=== which encoder did Sunshine pick? + mid-stream CUDA failures ==="
  grep -iE "trying encoder|encoder .* failed|found .* encoder|cuda_error|initialize cuda|map gl textures" \
    ~/.config/sunshine/sunshine.log | tail -15
  echo "=== rule out the other failure mode (sunshine/session) ==="
  pgrep -a sunshine; sudo ss -tlnp | grep 48010
  loginctl list-sessions --no-legend; ps -e | grep -E "kwin_wayland|plasmashell" | grep -v grep
'
```

The GPU has TWO wedge presentations — both go to Recovery A:

| What you see | Meaning | Go to |
|---|---|---|
| Stream **won't start**; `Couldn't initialize cuda: CUDA_ERROR_NOT_INITIALIZED` → `Encoder [nvenc] failed` → `Found H.264 encoder: libx264 [software]` | NVENC wedged at startup | Recovery A |
| Stream was working then **froze mid-use**; `dmesg` shows `NVRM: Xid 31/62/32` (`name=sunshine`) and/or Sunshine logs `CUDA_ERROR_LAUNCH_FAILED` / `Couldn't map GL textures`; `nvidia-smi` now **hangs** | GPU faulted live during the stream | Recovery A |
| **UEFI/GRUB-time artifacts on the TV** (corrupted color bands under readable boot text); after boot, `nvidia-smi` returns but shows `Fan ERR! Pwr ERR!`, `Disp.A: Off`, no Xid 62 yet OR Xid 62 in `journalctl -k`; `nv_queue` thread pegs ~90% CPU; `systemctl is-system-running` = `degraded`; **a `qm stop/start` produces an identical fresh-boot wedge** | Standby-power wedge — card retains corrupted internal state through warm reboots and even a host `poweroff`, because PCIe standby keeps it alive | Recovery C |
| Sunshine selects `nvenc` / `h264_nvenc`, no CUDA error, but stream still fails | Sunshine/session issue — GPU is fine | Recovery B |
| `sunshine` not running, no Plasma session, 48010 not listening | Sunshine didn't come up | Recovery B |

`nvidia-smi` looking healthy proves nothing (startup-wedge case); `nvidia-smi` *hanging* proves it's wedged (live-fault case).

`nvidia-smi` looking healthy proves nothing — the wedge is in CUDA/NVENC, not the
driver.

## Recovery A — GPU/NVENC wedged (the common case)

The card must be power-cycled. A VM restart alone will NOT fix it.

1. **(Optional, cheap, usually fails) clean VM re-attach** — only worth trying if
   you have *not* already stop/started anduril this incident:
   ```bash
   ssh earendil 'sudo qm stop 117 && sleep 8 && sudo qm start 117'
   ```
   Wait ~60s for the desktop session, re-run the diagnosis. Still
   `CUDA_ERROR`/libx264 → the card is genuinely wedged, continue.

2. **Power-cycle earendil — a COLD boot, not a warm `reboot`.** A warm reboot may
   not drop power to the card (this is why a `reboot` sometimes "doesn't work").
   All guests return on boot (anduril is `on_boot=true`).
   ```bash
   ssh earendil 'sudo poweroff'   # then Wake-on-LAN, or press the power button
   ```

3. **After earendil is back, confirm NVENC recovered:**
   ```bash
   ssh anduril 'grep -iE "trying encoder|found .* encoder|cuda_error" ~/.config/sunshine/sunshine.log | tail -6'
   ```
   You want Sunshine selecting **nvenc** with NO `CUDA_ERROR`. If it still shows
   libx264/CUDA error, the passthrough didn't attach cleanly on boot — do one
   fresh `ssh earendil 'sudo qm stop 117 && sleep 8 && sudo qm start 117'` and
   re-check.

4. Connect from Moonlight — it should stream.

## Recovery C — Standby-power wedge (harsher than Recovery A)

Verified 2026-06-01. Symptom set above. Distinguishing tell: **`qm stop/start`
brings the VM back up with the exact same Xid 62 / Fan-Pwr-ERR / 90%-nv_queue
state**. The card never lost power, so it never reset.

A normal `poweroff` of earendil is **not enough** — PCIe slot standby (3.3V
aux) keeps the card's internal microcontroller alive across a soft shutdown.

1. Shut down all guests cleanly, then earendil:
   ```bash
   ssh earendil 'sudo poweroff'
   ```
2. **At the chassis: flip the PSU rocker switch off** (or unplug the cord).
   Wait **3–5 minutes** for the 3.3V standby rail and on-card caps to drain.
3. Flip PSU back on, power earendil on, let all guests come up.
4. Confirm recovery on anduril:
   ```bash
   ssh anduril '
     nvidia-smi
     systemctl is-system-running
     journalctl -k -b 0 --no-pager | grep -iE "xid|nvrm.*err" | head
   '
   ```
   Want: `Fan: 0%`, `Pwr` reads a real wattage, `Disp.A: On`, no `Xid` in
   current boot, systemctl `running`.
5. Connect from Moonlight; should stream cleanly.

If after all of this the GPU still wedges within the first session, the card
is genuinely degrading — not just a stuck state — and replacement (per the
"only true permanent fix" section) becomes the actionable path.

## Recovery B — Sunshine/session problem (GPU is fine)

Diagnosis showed nvenc selected (no CUDA error), but the stream/ports/session are
off.

1. Confirm the autologin Plasma Wayland session is live:
   ```bash
   ssh anduril 'loginctl list-sessions --no-legend; ps -e | grep -E "sddm|kwin_wayland|plasmashell" | grep -v grep'
   ```
2. Restart the Sunshine user unit:
   ```bash
   ssh anduril 'XDG_RUNTIME_DIR=/run/user/1000 systemctl --user restart app-dev.lizardbyte.app.Sunshine.service'
   ```
3. If the session isn't up (no kwin/plasma), re-run the bring-up — it
   re-establishes SDDM autologin, linger, the keep-awake inhibit, and the
   Sunshine unit:
   ```bash
   cd ansible && ansible-playbook playbooks/setup-sunshine.yaml -l anduril --diff
   ```
4. Still broken: PBS-restore VM 117 to the last good snapshot, then
   `ansible-playbook playbooks/site-anduril.yaml -l anduril`. **A PBS restore does
   NOT fix a hardware GPU wedge** (that's Recovery A) — only use it when the GPU
   is fine but the guest config is broken.

## Verify recovered

- Moonlight launches a stream and it's stable.
- During a stream, `ssh anduril 'nvidia-smi'` shows non-zero encoder utilization.
- `~/.config/sunshine/sunshine.log` shows the nvenc encoder selected, no `CUDA_ERROR`.
- **Take a fresh PBS snapshot** of anduril once confirmed good — that becomes the
  new known-good baseline.

## Reduce recurrence

- **Never let the display mode/refresh change on a live session** — the usual
  wedge trigger. Stream at the dummy-plug's native resolution in Moonlight.
- Keep the **mangohud fps cap** (avoids the forced-V-Sync staircase that produces
  the tearing/stutter preceding crashes).
- **Proposed (not yet codified):** disable Sunshine's display-mode switching in
  `sunshine.conf` so it can never hot-modeset the card. See ROADMAP.

## The only true permanent fix

This is a **hardware limitation of the GTX 970**: no PCIe reset means a wedged
card can only be cleared by cutting its power. Every software mitigation just
reduces how often you hit it. A **Turing-or-newer GPU** (RTX 20-series+) has
function-level reset — a `qm stop`/`start` would reset it, no host reboot ever
needed — plus reliable HEVC/AV1 NVENC and current driver support (no 580 pin, no
mainline-kernel pin). If this keeps costing you evenings, that swap removes the
entire class of problem.
