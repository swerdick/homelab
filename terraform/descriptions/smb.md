# CT 121 — Samba (smb)

Unprivileged LXC serving macOS clients over SMB3. Exports selected ZFS datasets from `/bulk/*` as named shares.

## Container config

- **CT ID:** 121 · **Hostname:** `smb` (resolves as `smb.vingilot.internal`)
- **Unprivileged:** yes
- **Features:** `nesting=1` only — the "SMB/CIFS" feature checkbox is for *mounting* remote shares, not running a server. Leave it off.
- **Template:** Debian 12 standard · 2 cores · 512 MiB RAM

## Idmap (critical for unprivileged containers)

Host GID 10000 would normally appear as an unmapped high number inside the container. `/etc/pve/lxc/121.conf` contains a custom idmap mapping guest GID 10000 directly to host GID 10000:

```
lxc.idmap: u 0 100000 65536
lxc.idmap: g 0 100000 10000
lxc.idmap: g 10000 10000 1
lxc.idmap: g 10001 110001 55535
```

`/etc/subgid` on host includes `root:10000:1`.

**Don't re-append these lines.** "invalid map entry ... container uid 0 is also mapped" on start = duplicates in the conf file.

## Bind mounts

Per-dataset, same pattern as CT 120:

```
pct set 121 -mp0 /bulk/archive,mp=/bulk/archive,shared=1
pct set 121 -mp1 /bulk/documents,mp=/bulk/documents,shared=1
pct set 121 -mp2 /bulk/downloads,mp=/bulk/downloads,shared=1
pct set 121 -mp3 /bulk/games,mp=/bulk/games,shared=1
pct set 121 -mp4 /bulk/media,mp=/bulk/media,shared=1
pct set 121 -mp5 /bulk/photos,mp=/bulk/photos,shared=1
```

`/bulk/restore` intentionally not mounted — restic landing zone, never shared.

## Container-side setup

```
pct exec 121 -- groupadd -g 10000 shares
pct exec 121 -- useradd -M -s /usr/sbin/nologin -G shares smbuser
pct exec 121 -- apt-get install -y samba samba-common-bin
pct exec 121 -- smbpasswd -a smbuser
```

`smbuser` is the single SMB-authenticating identity. Samba password is independent of system password — managed via `smbpasswd`, stored in `/var/lib/samba/private/passdb.tdb`.

## /etc/samba/smb.conf

```
[global]
   workgroup = WORKGROUP
   server string = vingilot shares
   server min protocol = SMB3
   security = user
   map to guest = never
   disable netbios = yes
   smb ports = 445
   log file = /var/log/samba/log.%m
   max log size = 1000

   # macOS Finder niceties
   vfs objects = catia fruit streams_xattr
   fruit:metadata = stream
   fruit:model = MacSamba
   fruit:posix_rename = yes
   fruit:veto_appledouble = no
   fruit:wipe_intentionally_left_blank_rfork = yes
   fruit:delete_empty_adfiles = yes

[<share-name>]
   path = /bulk/<dataset>
   valid users = smbuser
   read only = no
   force group = shares
   create mask = 0664
   directory mask = 2775
```

`force group = shares` overrides smbuser's default group on every write — pairs with setgid on the directory so permissions stay consistent.

## Adding a share

```
# 1. Bind-mount the dataset (next free mpN)
pct stop 121
pct set 121 -mp6 /bulk/newthing,mp=/bulk/newthing,shared=1
pct start 121

# 2. Add stanza
pct exec 121 -- bash -c 'cat >> /etc/samba/smb.conf <<EOF

[newthing]
   path = /bulk/newthing
   valid users = smbuser
   read only = no
   force group = shares
   create mask = 0664
   directory mask = 2775
EOF'

# 3. Validate and reload
pct exec 121 -- testparm -s
pct exec 121 -- systemctl restart smbd
```

**Always run `testparm -s` before restarting.** Samba's config linter — catches typos, unknown parameters, section syntax errors.

In Finder: disconnect (eject arrow) and reconnect `smb://smb.vingilot.internal` to refresh the share list (cached per connection).

## Removing a share

```
# 1. Remove stanza from /etc/samba/smb.conf
# 2. Remove bind mount
pct stop 121
pct set 121 -delete mpN
pct start 121
# 3. Reload
pct exec 121 -- systemctl restart smbd
```

## Managing Samba users

```
# Add (must also exist as Linux user in container)
pct exec 121 -- useradd -M -s /usr/sbin/nologin -G shares <username>
pct exec 121 -- smbpasswd -a <username>

pct exec 121 -- smbpasswd <username>           # change password
pct exec 121 -- smbpasswd -d <username>        # disable
pct exec 121 -- pdbedit -L                     # list users
```

Restrict a share: set `valid users = user1 user2` in the share's stanza.

## macOS client

- Connect: Finder → ⌘K → `smb://smb.vingilot.internal`
- "Remember in keychain" on first connect
- Auto-mount: drag mounted share from Finder sidebar into System Settings → General → Login Items

## Troubleshooting

**Container won't start, idmap error:** check `/etc/pve/lxc/121.conf` for duplicate `lxc.idmap:` lines. Must be exactly 4.

**Shares show `nobody nogroup` inside container:** idmap not applied. Verify the 4 lines exist and `/etc/subgid` has `root:10000:1`.

**Permission denied writing:** smbuser not in `shares` group inside container, directory not group-writable on host, or setgid not set. Check `pct exec 121 -- id smbuser` and `ls -la /bulk/` on host.

**"Unknown parameter" in testparm:** typo. Fix before restarting smbd.

**Finder sees old share list:** disconnect and reconnect — per-connection cache.

**Logs:** `pct exec 121 -- tail -f /var/log/samba/log.smbd` and `/var/log/samba/log.<client-hostname>`.

