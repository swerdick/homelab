# Roadmap

Living list of work that's deliberately *not done yet*. New ideas land here; promote to a focused session when ready. Drop or rewrite when reality changes.

Things already done aren't tracked here — `git log` is the source of truth for that.

## Security & access hardening

### mTLS for Alloy → Prometheus

Currently basic auth (htpasswd / SOPS-encrypted password). Tirion's CA already issues client certs, so Alloy collectors could authenticate with mTLS instead of a shared password. Cleaner threat model; harder to leak; uses PKI we already maintain.

### Reduce sudo friction for the pseudo user

Since `~/.ssh/config` switched from `root` to `pseudo`, almost every interactive command on a host needs `sudo` in front of it. NOPASSWD sudo (`/etc/sudoers.d/pseudo`, set up by `setup-pseudo-user.yaml`) means there's no password prompt, but `pseudo` is still an unprivileged uid — so reading `/etc/pve/*`, editing `/etc/exports`, restarting services, and tailing root-owned logs all need the prefix. That's the deliberate cost of dropping root SSH; the question is how much of it can be reclaimed without dissolving the reason for the switch.

Options to weigh, roughly cheapest → most invasive:
- **`sudo -i` per session** — one command after SSH'ing in drops into a root shell for the rest of the session. Biggest practical win; cost is losing the visual reminder that you're root.
- **Group memberships for read-only paths** — adding `pseudo` to `adm` and `systemd-journal` covers `/var/log` reads + full `journalctl` without sudo. Doesn't help with writes or service restarts.
- **Per-host alias pair in `~/.ssh/config`** — `earendil` (pseudo, default) and `earendil-root` (root, explicit) so privileged work stays a deliberate choice. Keeps the namespace honest.
- **Shell wrappers on the mac** — `ssh host sudo …` aliases for frequent commands (`pvecm-status`, `flux-…`). Targeted but doesn't scale.

Pre-work: skim shell history on the two or three most-used hosts to see which command classes actually account for the friction — that should drive the choice, not the menu above.

### Pre-commit hook in a durable dotfiles repo

The private-key-marker pre-commit hook lives at `~/.config/git/hooks/pre-commit` on thorondor. Should be tracked somewhere — chezmoi-style dotfiles repo would be the natural home. "Future weekend" project.

## Observability

### Cert expiration alerting

Silent renewal failures (Proxmox ACME on earendil/erebor, cert-manager Certificates, step-ca's own root) could go unnoticed for weeks. Stack:
- `cert-manager` already exposes `certmanager_certificate_expiration_timestamp_seconds`; Prometheus already scrapes it.
- For non-k8s certs (Proxmox, step-ca), deploy `blackbox_exporter` and probe the HTTPS endpoints to surface `probe_ssl_earliest_cert_expiry`.
- `PrometheusRule` CRD with the threshold (e.g. 14d), `AlertmanagerConfig` for routing.

The whole thing also forces picking a notification channel (Discord webhook, ntfy.sh, email via Mailgun) — that's the rabbit-hole part.

### Flux health alerting

Stalled `HelmRelease` / `Kustomization` resources are silent failures from Flux's perspective once retries are exhausted. Capacitor shows them but you have to look. Add Prometheus alert on `gotk_reconcile_condition{type="Ready",status="False"}` (or similar) so a wedged release pages instead of being noticed days later. Pair naturally with the cert-expiration alerting work since the Alertmanager plumbing is the same.

### Flux observability dashboard in Grafana

Pre-built community dashboards exist (e.g. grafana.com/dashboards/16714). Quick win — import, tag `homelab`, run `just backup-grafana`, commit. Visual answer to "is Flux working" at a glance.

### Hardware status dashboard (SMART + hwmon)

A separate Grafana dashboard for physical-hardware metrics, mostly relevant on earendil (the only host with non-virtual disks). What goes on it:

- **Disk SMART**: temperatures, reallocated sector count, hours powered, projected SSD lifetime, current pending sectors. Needs a SMART exporter — `smartctl_exporter` is the modern actively-maintained choice; install on earendil via ansible (extension of `install-alloy.yaml` or its own playbook). Add `prometheus.scrape` in alloy's config to pull it.
- **Board hwmon**: CPU temperature, fan speeds, voltages. node_exporter's `hwmon` collector likely already exposes these on earendil — check `node_hwmon_temp_celsius` in Prometheus first; if so, this is purely a dashboard-build task with no new exporter needed.
- **Memory**: actual operating frequency (sanity-check after the XMP TODO in AGENTS.md eventually flips). Limited info from node_exporter; may need dmidecode-textfile-export or just rely on `journalctl | grep "DDR"` once.

The other guests (gondor VM, LXCs, anduril) see virtual disks, so SMART doesn't apply and hwmon mostly returns nothing. earendil is ~80% of the value here.

### Ship PVE/PBS task logs to Loki

systemd-journald (now flowing to Loki via Alloy) catches the bulk of host logs, but Proxmox writes its task/operation logs directly to files outside the journal:

- earendil: `/var/log/pveproxy/access.log`, `/var/log/pve/tasks/index` + per-task files in `/var/log/pve/tasks/{0..F}/UPID:...`, `/var/log/pve-firewall.log`
- erebor: `/var/log/proxmox-backup/api/access.log`, `/var/log/proxmox-backup/tasks/*`

These contain backup runs, snapshots, migrations, UI/API access — exactly what you want to query when something goes wrong overnight. Add `loki.source.file` components to the host alloy template (one per relevant path) plus appropriate label-extraction stages. APT history (`/var/log/apt/history.log`) is a smaller second candidate.

### Tempo for distributed tracing

Loki is up for logs (Phase 2 done) and Prometheus is up for metrics. Tempo is the third leg — Grafana's trace store. Same shape as Loki: HelmRelease + NFS-backed PVC + basic-auth route + Grafana datasource.

Why it'd matter: Alloy is OTel-capable (`otelcol.receiver.otlp` + exporter components), so any app that emits OTLP signals could ship traces here. Without Tempo, Alloy can still receive OTLP traces but has nowhere to forward them to. Currently relevant only if you instrument something yourself; nothing in the homelab fleet emits traces today.

Probably a Phase-2-of-Loki-style session: ~60-90 min for the chart + ingress + datasource, plus a follow-up to point Alloy at it once an actual app is producing traces.

## Apps & data services

### Immich machine-learning enable

Immich currently runs with `machine-learning.enabled: false` to keep memory predictable while the rest of the pipeline gets validated. Flipping it on adds ~1-2 GiB of RAM (the ML container holds CLIP + face-detection models in memory) and unlocks face grouping, smart search, and content-aware tagging. Wait until the capacity rebalance below frees up the budget on gondor; the deploy itself is a one-line values change.

### Immich non-root hardening

Server pod currently runs as `runAsUser: 0` with `supplementalGroups: [10000]` for `/bulk/*` access. Both `/bulk/photos` and `/bulk/media` are mounted `readOnly: true`, so the actual blast radius is small — but there's no reason to keep root. Flip to `runAsUser: 1000` + `runAsGroup: 1000` once the external-library scans are confirmed working end-to-end. Need to verify the immich-library PVC (managed library on `nfs-scratch`, written-to) tolerates the uid change; nfs-subdir-external-provisioner directories are mode 777 by default so it should.

### CNPG cluster backups (barman → Backblaze)

The Immich Postgres cluster is currently durability-insured only by gondor's PBS snapshots — crash-consistent at best, since PBS doesn't quiesce the database. CNPG has first-class barman-cloud support; pointing it at the Backblaze bucket aglarond already uses gives application-consistent base backups + continuous WAL archiving. Pre-flight: confirm aglarond's Backblaze creds are valid via a no-op `restic check` first, otherwise debugging happens during the wrong session. Configuration lives on the `Cluster` CR (`spec.backup.barmanObjectStore`) plus a `ScheduledBackup` CR for the cadence. Applies cluster-wide, not just to Immich — any future CNPG cluster benefits.

## Capacity & resource management

### Audit guest CPU/memory + rebalance

Some guests are over-provisioned. Per the host-overview dashboard:
- gondor has 10 GiB allocated; usage will climb when Immich's ML container is enabled (see "Immich machine-learning enable" above)
- LXCs allocate 1 GiB each, peak usage in the 150-300 MiB range
- Total host RAM is 16 GiB — the budget is real

Steps:
1. Sample memory usage on each guest over a representative window (include a backup run for erebor, streaming activity for media-using guests, an Immich library scan)
2. Identify safe shrinks (`allocated 1 GiB → peak 250 MiB → shrink to 512 MiB` style)
3. Apply via PVE UI (or via the eventual Terraform pivot — see README's "Where's the Terraform?")
4. Re-run `just dump-pve-configs` to capture the new shape
5. Reallocate the freed RAM to gondor — gives ML headroom on Immich and breathing room for future apps

~30-45 min once the targets are clear.

## Network & DNS

### Pi-hole / AdGuard for local DNS

Right now `vingilot.internal` records live on the Verizon CR1000A router. Adding any new internal hostname requires a manual A-record on the router *before* cert-manager can complete its HTTP-01 self-check (see [project memory](../.claude/projects/-Users-pseudo-repositories-homelab/memory/project_dns.md)).

A local resolver (Pi-hole or AdGuard Home) on a dedicated LXC would unlock wildcard `*.vingilot.internal → 192.168.1.220` and remove the per-service DNS friction. Probably a 2-hour session.

## Specific upgrades

### erebor (PBS) trixie upgrade

PBS 3 → 4 follows its own ritual; deferred until summer 2026 since PBS 3.x has security support through August. Inherently risky because erebor is the backup target — if the upgrade goes badly, restoring relies on the system you're upgrading. Snapshot first.

**Verify after upgrade**: `zfs-zed.service` is currently in a restart loop on PBS 3.x (visible in Loki: `Failed with result 'exit-code'` + `Scheduled restart job, restart counter is at 1006`). PBS 4 ships newer OpenZFS (2.3.x vs 2.2.x) and may resolve this. If it still flaps after the upgrade, investigate as a standalone issue.

### Alloy on erebor

Pending erebor's trixie upgrade — Alloy via the Grafana apt repo wants newer libc than PBS 3 ships. Once that's done, erebor joins the alloy fleet.

### Anduril in PBS backups + Ansible inventory + Alloy rollout

Three blockers stacked:
- **PBS backups**: anduril is excluded right now. Wants more RAM allocated before re-including (current size makes the backup quiesce window painful).
- **Ansible inventory**: not in `inventory.yaml` yet. Needs `ansible_become` settings for Bazzite.
- **Alloy install**: would also need OS-family branching (RPM-based, not apt). The existing `install-alloy.yaml` plays would need an `ansible.builtin.dnf` path or split.
- **distribute-root-ca**: anduril is currently skipped because Bazzite uses different cert paths and `rpm-ostree` semantics. Same OS-family branching applies.

All four naturally land in a single anduril-day session.

### XMP enable on RAM

See [`AGENTS.md` Hardware section](AGENTS.md#hardware). Free ~40% memory bandwidth; requires a full earendil reboot (homelab-wide outage) and a memtest86 pass. Pair with a planned maintenance window.

### iOS device trust

Each iOS device that wants to access internal HTTPS services needs the `vingilot` root CA in its trust store. Manual procedure: AirDrop the cert, install Profile, toggle on in Certificate Trust Settings. Captured in the CA-rotation runbook; just needs doing per device.

## Host-level configuration

### GPU passthrough setup on earendil — `setup-gpu-passthrough.yaml`

The GTX 970 is passed through to anduril for Moonlight game streaming. The host-side prerequisites (kernel cmdline, vfio modules, NVIDIA blacklist, `/etc/modprobe.d/vfio.conf` PCI bind) are currently manual on earendil and only documented in a comment block in `qemu/117.conf`. Worth lifting into a playbook:

- Add `intel_iommu=on iommu=pt` to `/etc/default/grub` (`GRUB_CMDLINE_LINUX_DEFAULT`), run `update-grub`
- Add `vfio`, `vfio_iommu_type1`, `vfio_pci` to `/etc/modules`
- Drop `/etc/modprobe.d/blacklist-nvidia.conf` (blacklists `nouveau`, `nvidia`, `nvidia_drm` so the host doesn't grab the card)
- Drop `/etc/modprobe.d/vfio.conf` binding the GPU's PCI IDs (detect via `lspci -nn | grep NVIDIA`, store in `host_vars/earendil.yaml` for visibility)
- `update-initramfs -u`
- Reports if a reboot is needed (touches `/var/run/reboot-required`)

Inherently risky — a misstep in the kernel cmdline or vfio config can prevent boot. Run `--check --diff` first, then real run during a planned outage window. Probably 45-60 min for the playbook + 30 min for reboot validation.

## Cleanup

### Re-document PVE guest configs after recent ansible work

The embedded `# ...` comment blocks at the top of several `/etc/pve/lxc/*.conf` files document procedures that are now superseded by ansible playbooks:

- **`120.conf` (nfs)** — "Adding an export" section uses `cat >> /etc/exports`. Now obsolete: `manage-nfs-exports.yaml` templates the file from `host_vars/nfs.yaml`.
- **`121.conf` (smb)** — same shape: "Adding a share" via `cat >> /etc/samba/smb.conf`. Now obsolete: `manage-samba-config.yaml`.

Recommended fix: edit the live `/etc/pve/lxc/120.conf` and `/etc/pve/lxc/121.conf` via the Proxmox UI's notes editor (or `vim` on earendil) to trim the obsolete sections and replace with one-liner pointers to the ansible playbooks. Then re-run `just dump-pve-configs` to refresh the local snapshot. Other config notes (PBS bootstrap on erebor, restic on aglarond, idmap on smb, bind-mount strategy) remain accurate.

## Generalize / refactor

### Ansible playbook for new-host onboarding

Codify the manual steps for adding a new homelab host into a single `bootstrap.yaml -l <new-host>`: distribute root CA, install unattended-upgrades, install alloy, ensure NFS client (`nfs-common`), set up the `pseudo` user, etc. Today these live as separate playbooks (or in `setup-k3s-pv-storage`'s third play in the case of `nfs-common`); an importing parent playbook would let `bootstrap.yaml` just pull them all in.

The `nfs-common` install in particular is currently buried inside `setup-k3s-pv-storage.yaml` because gondor was the only NFS client at the time. It should be lifted out into either a dedicated "ensure nfs client" playbook or this onboarding parent — pick whichever fits when a second NFS client actually appears.


