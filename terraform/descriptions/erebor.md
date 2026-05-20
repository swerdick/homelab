# CT 130 — Proxmox Backup Server (erebor)

Debian 12 LXC running PBS for guest backups. Datastore on host `/bulk/pbs`. Replaces the previous host-level vzdump job for guest backups; vzdump still runs weekly to capture PBS config (see `pbs-config-weekly` job).

## Container config

- **CT ID:** 130 · **Hostname:** `erebor` (`erebor.vingilot.internal`)
- **Unprivileged:** yes · **Features:** `nesting=1`
- **Template:** Debian 12 standard · 2 cores · 1 GiB RAM · 8 GiB rootfs
- **Network:** static IP 192.168.1.30 via router DHCP reservation (MAC `BC:24:11:B2:CF:BD`). No client-side static config — all reservations on router.
- **Onboot:** yes

## Bind mount

Datastore is the single bind mount — host `/bulk/pbs` (ZFS dataset, `compression=off` because PBS chunks are pre-compressed):

```
pct set 130 -mp0 /bulk/pbs,mp=/datastore
```

## Install

Inside the LXC console, no-subscription PBS:

```
echo "deb http://download.proxmox.com/debian/pbs bookworm pbs-no-subscription" \
  > /etc/apt/sources.list.d/pbs-no-subscription.list

wget https://enterprise.proxmox.com/debian/proxmox-release-bookworm.gpg \
  -O /etc/apt/trusted.gpg.d/proxmox-release-bookworm.gpg

apt update
apt install proxmox-backup-server
```

## PBS UI bootstrap

Web UI: <https://erebor.vingilot.internal:8007> · log in as `root@pam`.

1. **Datastore:** Datastore → Add → name `main`, backing path `/datastore`.
2. **API token for host:** Configuration → Access Control → API Token. User `root@pam`, token name `earendil-host`, Privilege Separation off (or scope appropriately). Save the secret immediately — shown once.
3. **Note datastore fingerprint:** Configuration → Certificates → SHA-256 fingerprint.

## Host-side registration

Datacenter → Storage → Add → Proxmox Backup Server:
- ID: `pbs-main`
- Server: `erebor.vingilot.internal`
- Datastore: `main`
- Username: `root@pam!earendil-host`
- Password: API token secret
- Fingerprint: from PBS Certificates page

## Backup job

`guests-to-pbs` — defined at host level (Datacenter → Backup), targets `pbs-main`, includes CTs 120, 121, VM 117.

**No schedule on the job.** Triggered by host orchestrator at `/etc/systemd/system/nightly-backup.service` so the whole pipeline (vzdump → PBS → restic) stays sequenced and gets `Persistent=true` catch-up behavior.

## SSH

`pseudo` user with key auth. Root SSH not permitted.

## Troubleshooting

**"connection refused" from host to PBS:** firewall on container, or PBS service not running. `pct exec 130 -- systemctl status proxmox-backup`.

**Fingerprint mismatch after PBS reinstall:** PBS regenerated certs. Update the fingerprint in Datacenter → Storage → pbs-main → Edit.

**Datastore appears empty after restart:** verify bind mount is alive: `pct exec 130 -- ls /datastore`. If empty, host-side mount config issue.

**Logs:** `journalctl -u proxmox-backup` and `/var/log/proxmox-backup/tasks/` inside the LXC.

Known quirk: On erebor (PBS), cert orders complete successfully but proxmox-backup-proxy may continue serving the previous cert until restarted. Reboot or systemctl restart proxmox-backup-proxy after any cert order/renewal. Earendil (PVE) does not have this issue

