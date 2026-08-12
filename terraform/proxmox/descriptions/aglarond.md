# CT 131 — Restic offsite backups (aglarond)

Debian 12 unprivileged LXC. Reads source data via read-only bind mounts, encrypts client-side, ships to Backblaze B2 bucket `earendil-vingilot-internal`.

## Bind mounts

```
mp0  /bulk/pbs              -> /srv/pbs              (ro)
mp1  /scratch/backups       -> /srv/scratch-backups  (ro)
mp2  /etc                   -> /srv/host-etc         (ro)
mp3  /bulk/restic-cache     -> /var/cache/restic     (rw, cache)
mp4  /bulk/documents        -> /srv/documents        (ro)
mp5  /bulk/media/music      -> /srv/music            (ro)
mp6  /bulk/photos           -> /srv/photos           (ro)
mp7  /bulk/media/wallpaper  -> /srv/wallpaper        (ro)
```

(A planned mp8 for `/bulk/media/movies` was never actually added — movies are **not** in offsite backup today.)

Add via host: `pct set 131 -mpN /host/path,mp=/srv/whatever,ro=1` then `pct reboot 131`.

## GID 10000 passthrough (media access)

The /bulk media trees are `2770 :10000` (the k8s supplementalGroups model), which the unprivileged mapped root (host uid/gid 100000) cannot read — this silently broke `restic-media` for months in 2026 (0-byte "hollow" snapshots). Access is granted the same way the smb CT does it: `/etc/pve/lxc/131.conf` maps guest GID 10000 directly to host GID 10000, and a drop-in runs `restic-media` with `SupplementaryGroups=10000` (guest group `shares`):

```
lxc.idmap: u 0 100000 65536
lxc.idmap: g 0 100000 10000
lxc.idmap: g 10000 10000 1
lxc.idmap: g 10001 110001 55535
```

Managed by `ansible/playbooks/setup-aglarond.yaml` (idmap, `/etc/subgid`, `shares` group, service/timer drop-ins, host-etc excludes). Idmap changes need a CT restart — never restart mid-backup.

## Three backup sets

| Service | Sources | Schedule (UTC) | Retention |
|---|---|---|---|
| `restic-backups` | pbs + scratch-backups | Daily 20:30 | 30 daily |
| `restic-host` | host-etc | Daily 21:15 | 14d / 8w / 12m |
| `restic-media` | photos, documents, music, wallpaper (movies: no mount, see above) | Sun 21:30 | 12m / 5y |

Schedules and throttling (Nice/CPUQuota) come from drop-ins managed by `setup-aglarond.yaml`. Moved from 02:00-03:00 UTC in 2026-08: those slots sat in prime evening gaming hours (22:00-23:00 ET, CPU/IO contention with anduril) and raced the ~23:15 ET fleet shutdown, which killed long B2 uploads mid-flight. 20:30 UTC lands after the 14:00 earendil-local vzdump finishes in both DST offsets.

All timers use `Persistent=true` for catch-up after Earendil power-on.

## Restic config — `/root/.config/restic/`

| File | Purpose |
|---|---|
| `password` | Repo encryption key (also in Bitwarden — losing it = unrecoverable) |
| `b2.env` | B2 credentials, repo location, cache dir |
| `includes-{backups,host,media}.txt` | Source paths per job |
| `excludes-host.txt` | Skip list for host-etc (unreadable from unprivileged LXC) |

Edit with `vim`. No daemon-reload needed for include/exclude changes — restic re-reads at every run.

`/root/.bashrc` auto-sources `b2.env` so interactive `restic` commands work without manual sourcing.

## Systemd

```
# Manual trigger (use --no-block for long jobs so shell returns)
systemctl start --no-block restic-backups.service
systemctl start restic-host.service
systemctl start restic-media.service

systemctl status restic-backups.service
systemctl list-timers restic-*
systemctl cat restic-backups.service       # see unit as systemd parses it
systemctl daemon-reload                    # after editing unit files
```

## Tailing logs

```
journalctl -u restic-backups.service -f          # follow live
journalctl -u restic-host.service -n 50          # last 50 lines
journalctl -u 'restic-*' -f                      # all three at once
journalctl -u restic-backups.service -p err      # errors only
journalctl -u restic-media.service --since today
```

## Interactive restic

```
restic snapshots                       # list all
restic snapshots --tag backups         # filter
restic stats --mode raw-data           # logical vs deduped
restic check                           # metadata integrity
restic check --read-data-subset=10%    # spot-check chunks
```

## Restoring

```
mkdir /tmp/restore
restic restore latest --tag media \
    --target /tmp/restore \
    --include /srv/photos/2024-trip/IMG_1234.jpg

# Browse a snapshot via FUSE
mkdir /mnt/restic
restic mount /mnt/restic
# ls /mnt/restic/snapshots/<id>/  ;  Ctrl-C to unmount
```

Restored files land at original absolute paths under `--target`. So `--target /tmp/restore` + `--include /srv/photos/foo.jpg` produces `/tmp/restore/srv/photos/foo.jpg`.

## Common issues

**"Please specify repository location":** env vars not loaded. Source `b2.env` manually or check `/root/.bashrc`.

**"permission denied" on /srv/host-etc/foo:** unprivileged LXC can't read host-root-owned files. Add to `excludes-host.txt`. Service exits status 3 (warning) but snapshot still saves.

**B2 "storage cap exceeded":** raise cap in B2 console → Caps & Alerts. Manually retry: `systemctl start --no-block restic-backups.service` — uploads resume from where they stopped.

**`systemctl start` hangs:** expected for `Type=oneshot` — it waits for completion. Use `--no-block` or Ctrl+C the wait (service keeps running).

**Container won't start, idmap error:** check `/etc/pve/lxc/131.conf` for duplicate `lxc.idmap:` lines. Must be exactly 4, and `/etc/subgid` must contain `root:10000:1`.

**restic-media "permission denied" on all /srv sources (0 B added):** the gid-10000 passthrough isn't active — CT not restarted since the idmap landed, or the `SupplementaryGroups=10000` drop-in is missing. Re-run `setup-aglarond.yaml` and `pct reboot 131` (not mid-backup). Watch for this after any /bulk permission restructuring: it produces hollow snapshots that look current.

## Recovery (total Earendil loss)

1. Reinstall Proxmox, recreate ZFS pools (commands in earendil host notes)
2. Install restic, configure with same password + B2 creds
3. `restic snapshots` to confirm access
4. Restore `/srv/host-etc` → `/etc`
5. Restore `/srv/pbs` → `/bulk/pbs`, rebuild PBS LXC pointing at it
6. Restore guests from recovered PBS datastore
7. Restore media subset to `/bulk/{photos,documents,...}`

