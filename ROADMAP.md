# Roadmap

Living list of work that's deliberately *not done yet*. New ideas land here; promote to a focused session when ready. Drop or rewrite when reality changes.

Things already done aren't tracked here — `git log` is the source of truth for that.

## Security & access hardening

### Pseudo users + sudo on root-only hosts

Currently `aglarond`, `tirion`, `earendil` (and the `nfs` / `smb` LXCs) are accessed as `root` directly. Goal: a `pseudo` user on every host with SSH-key auth and sudo (NOPASSWD or password — TBD), so day-to-day login follows least-privilege ergonomics and `sudo` logs give attribution.

Estimated ~45–60 min per host because lockout risk is real (validate from a parallel SSH session before logging out of the original). **tirion specifically lacks `sudo` entirely** (see [project memory](../.claude/projects/-Users-pseudo-repositories-homelab/memory/project_tirion_no_sudo.md)) — would need either `apt install sudo` or a `doas` setup as part of the work.

### mTLS for Alloy → Prometheus

Currently basic auth (htpasswd / SOPS-encrypted password). Tirion's CA already issues client certs, so Alloy collectors could authenticate with mTLS instead of a shared password. Cleaner threat model; harder to leak; uses PKI we already maintain.

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

### CloudNativePG operator (Postgres platform)

Foundation for Immich (and any future app that wants Postgres). CNPG is the actively-maintained, k8s-native Postgres operator — lightweight, supports backup to S3-compatible (Backblaze, which `aglarond` already has creds for), point-in-time recovery, replication, automated failover.

Tasks:
- HelmRelease under `gondor/infrastructure/controllers/cnpg/` (operator install)
- A `Cluster` manifest for an Immich-flavored Postgres using `tensorchord/cloudnative-pg-vectorchord` (vectorchord extension is required for Immich's face/object recognition features)
- Test pod that connects to validate
- Optional: wire backup to Backblaze in the same session

Worth its own ~60-90 min session before Immich.

### Jellyfin

Self-hosted media server. Lightweight: ~1 GiB memory request, no DB, just config + media PVCs. Plugs into the existing NFS-backed media on `/bulk/media`.

- Config PVC on `local-path` (5 Gi). Media PVC referencing the existing NFS export.
- New HTTPRoute + Gateway listener + Cert + DNS record (`jellyfin.vingilot.internal → 192.168.1.220`).
- No GPU on gondor (GTX 970 is passed through to anduril) → software transcoding only. Fine for single-stream direct-play of common codecs, painful at 4K/HEVC re-encode.

### Immich

Self-hosted photo library with face/object recognition. Heavier than Jellyfin: needs Postgres-with-vectorchord (provided by CNPG above) + Valkey (`valkey.enabled: true` in the chart bundles it) + a beefy machine-learning container if AI features are enabled.

Resource sketch on gondor:
- With ML: ~4-5 GiB total across server/microservices/ml + Postgres + Valkey
- Without ML: ~2-3 GiB; loses face grouping and content-search but otherwise full-featured

Recommend deploying with ML disabled first to validate the pipe end-to-end, then flip ML on once memory is confirmed (likely after the capacity rebalance below). Library PVC on `nfs-scratch` or a new bulk-backed export. New HTTPRoute + Gateway listener + Cert + DNS (`immich.vingilot.internal`).

## Capacity & resource management

### Audit guest CPU/memory + rebalance

Some guests are over-provisioned. Per the host-overview dashboard:
- gondor has 10 GiB allocated, uses ~3.5-4 GiB (will grow with Loki/Alloy/Immich)
- LXCs allocate 1 GiB each, peak usage in the 150-300 MiB range
- Total host RAM is 16 GiB — the budget is real

Steps:
1. Sample memory usage on each guest over a representative window (include a backup run for erebor, plex/streaming activity for media-using guests)
2. Identify safe shrinks (`allocated 1 GiB → peak 250 MiB → shrink to 512 MiB` style)
3. Apply via PVE UI (or via the eventual Terraform pivot — see README's "Where's the Terraform?")
4. Re-run `just dump-pve-configs` to capture the new shape
5. Reallocate the freed RAM to gondor as Immich's appetite demands

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

## Generalize / refactor

### Ansible playbook for new-host onboarding

Codify the manual steps for adding a new homelab host into a single `bootstrap.yaml -l <new-host>`: distribute root CA, install unattended-upgrades, install alloy, etc. Today these live as separate playbooks; an importing parent playbook would let `bootstrap.yaml` just pull them all in.

### `nfs-common` install — generalize beyond k3s

Currently the `setup-k3s-pv-storage` playbook installs `nfs-common` on gondor as a third play. If/when other guests need to mount NFS, that play should move to a generic "ensure nfs client" playbook (or fold into the new-host onboarding playbook above) rather than living inside the k3s storage one.

### Manage NFS exports in ansible

Today only the `/scratch/k3s-pvs` export is managed by the `setup-k3s-pv-storage` playbook. The pre-existing exports (`/bulk/media`, `/bulk/photos`, `/bulk/documents`, etc.) are hand-edited in the nfs LXC's `/etc/exports`. Once Jellyfin/Immich start consuming media via NFS we'll want to tweak exports more often — bring them all under ansible before that happens.

Approach: move `/etc/exports` to a Jinja template at `ansible/templates/etc-exports.j2`, define each export as a structured entry in `group_vars/`, write a `manage-nfs-exports.yaml` playbook that templates + reloads. Existing pseudo-root-at-`/` layout stays.

### Manage Samba config in ansible

Same story for the smb LXC: `/etc/samba/smb.conf`, share definitions, user mappings — none of it currently in ansible. Bring under management before the next "add a share" or "tweak permissions" task. Pattern mirrors the NFS one above (template + playbook + handlers).

### `tirion-root-ca` Secret cleanup

Originally a manually-applied Secret for cert-manager bootstrap; replaced by inlining the cert into the `ClusterIssuer`'s `caBundle:`. The old Secret may still be lingering in-cluster. Verify and `kubectl delete` if so. Mostly hygiene.
