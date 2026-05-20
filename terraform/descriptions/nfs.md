# CT 120 — NFS (nfs)

Privileged LXC running kernel NFSv4 server. Exports selected ZFS datasets from `/bulk/*` to LAN clients — primarily future k3s VM for persistent volumes, occasionally Linux machines.

## Container config

- **CT ID:** 120 · **Hostname:** `nfs` (resolves as `nfs.vingilot.internal`)
- **Privileged:** yes — kernel NFSd needs capabilities the unprivileged set doesn't grant
- **Features:** `nesting=1`, `nfs=1` (the `nfs` feature is greyed out for unprivileged containers)
- **Template:** Debian 12 standard · 2 cores · 1 GiB RAM

The "NFS" feature checkbox is for running the NFS *server*. The "SMB/CIFS" checkbox is for *client* mounts — don't confuse them.

## Idmap

**Not needed.** Privileged containers have 1:1 UID/GID mapping to the host, so host GID 10000 is guest GID 10000 without translation. No `lxc.idmap` lines in `/etc/pve/lxc/120.conf`.

## Bind mounts

Each `/bulk/*` ZFS dataset gets its own mount point — single `/bulk` mount doesn't work because ZFS sub-datasets are independent filesystems and bind mounts don't cross filesystem boundaries.

```
pct set 120 -mp0 /bulk/archive,mp=/bulk/archive,shared=1
pct set 120 -mp1 /bulk/documents,mp=/bulk/documents,shared=1
pct set 120 -mp2 /bulk/downloads,mp=/bulk/downloads,shared=1
pct set 120 -mp3 /bulk/games,mp=/bulk/games,shared=1
pct set 120 -mp4 /bulk/media,mp=/bulk/media,shared=1
pct set 120 -mp5 /bulk/photos,mp=/bulk/photos,shared=1
```

Diagnostic for empty sub-datasets: if `stat /bulk/media` on host vs `pct exec 120 -- stat /bulk/media` show different inode/Device values, the container is seeing a placeholder, not the dataset.

## Container-side setup

```
pct exec 120 -- groupadd -g 10000 shares
pct exec 120 -- apt-get install -y nfs-kernel-server
```

No service user — NFS authenticates by UID/GID on the wire (with default `sec=sys`), not via a named account.

## /etc/exports

NFSv4-only with pseudo-root at `/bulk`:

```
/bulk          192.168.0.0/16(rw,sync,fsid=0,crossmnt,no_subtree_check,root_squash)
/bulk/media    192.168.0.0/16(rw,sync,no_subtree_check,root_squash)
/bulk/photos   192.168.0.0/16(rw,sync,no_subtree_check,root_squash)
/bulk/documents 192.168.0.0/16(rw,sync,no_subtree_check,root_squash)

# Uncomment when k3s VM exists — pods may run as root
# /bulk/k3s-pvs  192.168.0.0/16(rw,sync,no_subtree_check,no_root_squash)
```

### Export options

| Option | Meaning |
|---|---|
| `192.168.0.0/16` | LAN-only |
| `rw` / `sync` | Read-write, writes committed before ACK |
| `fsid=0` | NFSv4 pseudo-root marker (exactly one export gets this) |
| `crossmnt` | Clients can traverse from pseudo-root to sub-exports |
| `no_subtree_check` | Modern default |
| `root_squash` | Demotes client UID 0 to `nobody` |
| `no_root_squash` | Trusts client root — needed for k3s PVs |

## Adding an export

```
# 1. Bind-mount dataset (next free mpN)
pct stop 120
pct set 120 -mp6 /bulk/newthing,mp=/bulk/newthing,shared=1
pct start 120

# 2. Add export line
pct exec 120 -- bash -c 'cat >> /etc/exports <<EOF
/bulk/newthing 192.168.0.0/16(rw,sync,no_subtree_check,root_squash)
EOF'

# 3. Reload (no service restart needed)
pct exec 120 -- exportfs -ra
pct exec 120 -- exportfs -v
```

## Removing an export

```
# 1. Remove line from /etc/exports
# 2. Reload
pct exec 120 -- exportfs -ra
# 3. Remove bind mount if no longer needed
pct stop 120
pct set 120 -delete mpN
pct start 120
```

## Mounting from clients

### Linux (including k3s nodes)

```
apt-get install -y nfs-common
mkdir -p /mnt/media
mount -t nfs4 nfs.vingilot.internal:/media /mnt/media
```

Path is `:/media`, not `:/bulk/media` — pseudo-root makes sub-exports appear as direct paths. Persistent in `/etc/fstab`:

```
nfs.vingilot.internal:/media  /mnt/media  nfs4  defaults,_netdev  0  0
```

### macOS (diagnostic only — use SMB for regular Mac use)

```
sudo mkdir -p /Volumes/nfstest
sudo mount -t nfs -o resvport,vers=4 nfs.vingilot.internal:/media /Volumes/nfstest
```

`resvport` forces a privileged source port (Finder won't). Writes as root denied by `root_squash` — correct, not a bug.

## Kubernetes PVs (future)

```
apiVersion: v1
kind: PersistentVolume
metadata:
  name: media-pv
spec:
  capacity: { storage: 500Gi }
  accessModes: [ReadWriteMany]
  nfs:
    server: nfs.vingilot.internal
    path: /media
  mountOptions: [nfsvers=4]
```

Pods that write must include `supplementaryGroups: [10000]` in the security context so the container process is a member of `shares` server-side.

## Troubleshooting

**No exports active:** `pct exec 120 -- exportfs -v`. Empty = syntax error in `/etc/exports`.

**`showmount -e` hangs:** firewall/routing. Container firewall off by default.

**`showmount -e` "Connection refused":** service not running. `pct exec 120 -- systemctl status nfs-server`. `active (exited)` is normal — nfs-server is a oneshot that starts kernel threads and exits.

**Mount succeeds, write fails Permission denied:** `root_squash` working. Write from a UID in `shares` (GID 10000), or use `no_root_squash`.

**k3s pod can't write to PV:** add `supplementaryGroups: [10000]` to pod SecurityContext. Verify with `kubectl exec ... -- id`.

**Sub-dataset empty inside container:** bind mount targeting parent placeholder. Use per-dataset bind mounts.

**Logs:** `pct exec 120 -- journalctl -u nfs-server`, container `dmesg`.

