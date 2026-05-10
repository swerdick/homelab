# Roadmap

Living list of work that's deliberately *not done yet*. New ideas land here; promote to a focused session when ready. Drop or rewrite when reality changes.

When something ships, move it to **Completed** at the bottom as a one-line bullet — that gives an at-a-glance "what's been built" view without bloating the active sections. `git log` remains the canonical source for the *how*.

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

### Add CloudWatch as a Grafana datasource

User's Grafana Cloud instance currently queries CloudWatch from a personal AWS account; some dashboards live there. Get the same view on the local Grafana so AWS metrics aren't trapped behind Grafana Cloud.

Steps: extend `apps/observability/kube-prometheus-stack.yaml` `grafana.additionalDataSources` (alongside the existing Loki entry) with a CloudWatch entry. AWS auth via IAM access-key pair stored in a SOPS-encrypted Secret. Recreate / import the existing dashboards, tag `homelab`, run `just backup-grafana`. Set the datasource's default interval to 5m or higher — CloudWatch GetMetricData calls are billed and a tight refresh loop quietly racks up charges.

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

### Deploy Vibeseeker to local k3s

User's own app — currently developed elsewhere, wants a stable in-cluster deployment as a real "production"-feeling target. Standard shape: HelmRelease in a `vibeseeker` namespace, HTTPRoute at `vibeseeker.vingilot.internal` (or whatever public hostname makes sense via Cloudflare Tunnel), CNPG-backed Postgres if it needs persistent state, image pulled from the local registry (see CI/CD section) or upstream until that lands. Image probably built by self-hosted GHA runners — three of the CI/CD items below are natural preconditions if the goal is full local dev-loop.

## CI/CD & developer infrastructure

### Self-hosted GitHub Actions runners

GitHub-hosted runners have monthly minute caps and can't reach internal homelab services without exposing them. Self-hosted runners give faster builds + access to in-cluster registries, databases, and the future SonarQube/Harbor/Vibeseeker triad below. Two viable shapes:

- **`actions-runner-controller` (ARC) in k3s** — operator scales runner pods up on workflow events, down to zero between. GitHub App authentication. Most-homelabby choice; deploys via HelmRelease, plays well with Flux.
- **Docker-based runners on a dedicated LXC** — simpler, no scale-to-zero. Lower complexity but always-running cost.

Security: a self-hosted runner executes whatever workflow code is in the repo. Restrict via `runs-on: self-hosted` + first-time-contributor approval, and isolate runners from credential-bearing infrastructure (separate namespace, no cluster-admin). Pairs with the local registry + security scanning items below.

### Gitea / Forgejo as GitHub mirror

Single-failure-domain risk: any of "GitHub repo disappearing" (account suspension, outage, policy change) cripples Flux which reconciles from `github.com/swerdick/homelab.git`. A local Gitea (or its more-active fork Forgejo) running as a HelmRelease can mirror every repo we care about on a schedule.

HelmRelease in `gitea` namespace, CNPG-backed Postgres (extends the operator pattern Immich already uses), HTTPRoute at `gitea.vingilot.internal`, NFS-backed PVC for repo storage. Configure each repo as a "pull mirror" against GitHub. Optionally re-point Flux's `GitRepository` at the local Gitea once it's been operating reliably — full dogfooding, GitHub becomes the upstream-of-the-mirror.

Mirror-only is the right scope. Pushing changes back to GitHub stays the source-of-truth flow; local Gitea is the read-only insurance copy.

### Local container + Helm registry (Harbor)

Two motivations: (1) external Helm charts and container images can vanish or rate-limit at the worst time — a chart's index.yaml going away breaks Flux mid-deploy. (2) Need a write target for the security-scanning item below.

**Harbor** is the natural fit — bundles an OCI registry + Helm chart support + replication policies + Trivy-based vuln scanning + RBAC + a UI, CNCF-maintained. Helm-installable. Storage on NFS-backed PVC (50-100 GiB to start; will grow). Replication policies pull-mirror upstream registries on a schedule (Docker Hub, ghcr.io, quay.io, immich-app.github.io). Apps re-point at `harbor.vingilot.internal/library/...` instead of upstream URLs; Flux's `HelmRepository` resources can also reference Harbor's `oci://` Helm support.

Lighter alternative if Harbor's UI/RBAC are overkill: **Zot** (OCI-only, tiny). Sonatype Nexus / JFrog are realistically paid-tier for the features that matter here; skip.

### Security scanning (Trivy)

Pairs with the registry above and runs in two modes that share the same scanner:
- **Registry-side**: Harbor's bundled Trivy scanner auto-scans every image that lands. Surfaces CVE counts per repo/tag in the Harbor UI. Free if Harbor lands.
- **CI-side**: `aquasecurity/trivy-action` in GitHub Actions workflows scans images before they're pushed. Pairs with self-hosted runners.

Both modes incremental — pick one and the other is a small additional step. Threshold gates (fail build on HIGH+ CVEs) come later; first goal is "we can see CVE counts at all."

### Self-hosted SonarQube for static analysis

Static-analysis side of the quality/security story (Trivy covers CVEs; SQ covers code smells / bugs / coverage / duplications). Community Edition is free, Helm-installable, Postgres-backed — extends the existing CNPG operator pattern.

Resource cost is the gotcha: ~3-4 GiB RAM for the SQ server idle, plus CPU spikes during analysis runs. Almost certainly lands *after* the gondor capacity rebalance, or runs as a dedicated PVE LXC if it doesn't fit in k3s.

GitHub Actions integration via `sonarsource/sonarqube-scan-action` — works cleanly when the runner can reach the SQ server over the in-cluster network. So this item realistically depends on self-hosted runners landing first; cloud-runner access would need Cloudflare Tunnel + auth gymnastics that aren't worth it.

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

If the Pi-orchestrator proposal (see Proposals at the bottom) lands, the resolver lives there (natively, not in k3s) and supersedes this entry.

### Headscale / Tailscale for remote access

Mesh VPN replaces per-service Cloudflare Tunnels for SSH and admin access — every device on the tailnet gets a stable address regardless of where it physically is, and homelab services that don't need public exposure can stay tailnet-only. Where it runs depends on the Pi-orchestrator proposal (see Proposals): ideal home is the always-on Pi as a native daemon, with fallbacks of a HelmRelease on gondor or a PVE LXC on earendil.

Two related capabilities to layer in once the coordinator is up:
- **Tailscale subnet router**: announce `192.168.1.0/24` so the whole LAN is reachable through one node — no per-LXC client install.
- **WoL bridge**: a small HTTP service on the tailnet that wakes earendil via magic packet from anywhere (described in the Pi-orchestrator entry).

If the Pi-orchestrator item slips, this becomes a different decision: Headscale-as-k3s-pod buys remote access only while gondor is up (daytime-only under the nightly-shutdown model). Cloudflare Tunnel stays the answer for "always reachable" public HTTP. Headscale only earns its place if SSH/non-HTTP access is part of the use case.

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

### Earendil TZ alignment (America/New_York → UTC)

The only host in the fleet not on UTC — surfaced when `setup-debian-base.yaml` ran against `debian_guests` and earendil (in `proxmox_hosts`, untargeted) was left behind. The on-host visibility benefit of converging is small (Grafana already normalizes log display TZ in the browser), but the inconsistency is a paper-cut every time you SSH in to read `journalctl` directly. Real risk on the flip: anything scheduled in local time shifts by 4-5 hours when the TZ moves.

Pre-flight before `timedatectl set-timezone UTC`:
- `crontab -l` for root + pseudo, plus `/etc/crontab` and `/etc/cron.d/*` — convert any local-time entries to UTC equivalents
- PVE UI → Datacenter → Backup (and `/etc/pve/jobs.cfg` for replication / HA) — convert each Schedule field
- `systemctl list-timers --all` — audit `OnCalendar=` entries for absolute hours
- Whatever automation powers the nightly shutdown — confirm in scope and convert

Then flip and verify next-run times of each converted entry match expectation. ~30-60 min focused session; defer until a low-stakes window since earendil is the host everything else depends on.

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

## Proposals

Items above are "decided, just need time." Items in this section are speculative — captured so the thinking doesn't rot, but not committed to. Graduation to a section above means a decision was made.

### Measure earendil idle/load wattage with Kill-A-Watt

Drives the cost-justification side of the nightly-shutdown calculus. Today the decision rests on a guess (~35-65W idle, varying heavily on whether the GTX 970 enters deep idle when passed through to a powered-off anduril). Without a real number, downstream decisions like "is the Pi-orchestrator proposal worth the architectural cost" are unanchored.

Setup: Kill-A-Watt meter inline with earendil's PSU for at least a full week. Capture three states if practical:

- **Earendil idle, anduril off** (current default state) — shows the GPU-passthrough idle overhead
- **Earendil idle, anduril running** — shows full normal operating cost
- **Earendil under load** (PBS backup window, Immich job runs) — shows realistic peak

Outcome: a real $/yr cost figure for nightly shutdown vs always-on, and a sanity check on whether vfio-pci is keeping the GTX 970 out of deep idle (suspected, not confirmed).

### Pi 5 as always-on companion node (architecture not settled)

Driver: earendil shuts down nightly, so anything in-cluster (DNS, Headscale, observability, scheduled jobs) disappears for ~12h every day. A Pi 5 always-on solves that whole class of problems. The shape it takes is the open question.

**Two shapes under consideration:**

*Phase 1 — Pi as native appliance, optionally a k3s worker:*
- Pi-hole/AdGuard, Headscale, watering all run as native systemd services on the Pi (Ansible-managed). Always available, never depend on cluster health.
- Pi optionally joins k3s as a worker for ARM-tagged pods (Vibeseeker, etc.) — daytime-active when gondor's API server is reachable; cached pods coast through nightly shutdown but no new scheduling.
- ~30-min Pi join, easy backout. Sets up Phase 2 naturally if the limitations are concretely felt.

*Phase 2 — Pi promoted to k3s control plane:*
- Resolves "API server gone overnight" — CronJobs fire, Flux reconciles, kubectl works at 3am.
- Heavier migration: relocate gondor's local-path PVs, re-bootstrap flux-system at the new endpoint, ~2-4h planned outage. Trust the Pi to host etcd/SQLite writes 24/7 (USB SSD non-negotiable).
- Worth doing if/when Phase-1 limitations are concretely felt — don't preemptively pay this cost.

**Things settled regardless of phase:**
- USB-SSD boot, not SD card (k3s + Alloy WAL + Pi-hole logs would shred an SD card in months). Wired Ethernet only — WiFi causes API/kubelet flapping.
- Pi-hole/Headscale stay native — DNS shouldn't depend on k3s health, and DNS feeds the cluster on Pi reboot before kubelet starts.
- Watering = systemd timer + Python script natively. Doesn't need a cluster regardless of topology.
- Bonus capability: SSH-via-Headscale-to-Pi → `wakeonlan` magic packet → wakes earendil. Lab boots in 2-5 min from anywhere on the tailnet.

**Open questions before this graduates from proposal:**
- **Cost-justified?** Depends on the Kill-A-Watt measurement above. If earendil idles at 60W with the GTX 970 holding power, nightly shutdown saves more and the Pi pattern earns its place financially. If it idles at 35W, the savings are thin and the Pi becomes pure operational-leverage / learning play (still legitimate — over-engineering for learning is the point of the homelab).
- **Watering deadline.** If auto-water needs to ship for *this* growing season, Phase 1 native is the only path that ships in time.
- **One Pi or two?** Orchestrator wants "next to the switch with wired link"; watering wants "near the plants." A dedicated cheap Pi (Pi 4 / Zero 2 W) for plants is the obvious resolution if those goals conflict.
- **CR1000A as DNS fallback.** Router can hand out a secondary DNS — useful safety net for "Pi failed at 2am," but the leak-through behavior on Windows/Linux clients (clients sometimes prefer/cache the secondary) isn't great.

---

## Completed

Reverse-chronological — most recent first. One line each; `git log` carries the rest.

- **Samwise (Raspberry Pi 5) onboarded** — added to `sudo_hosts` / `physical_hosts` / `debian_guests` / `alloy`; running RPi OS Lite Trixie (aarch64) on WiFi + SD card; baseline (`setup-pseudo-user` / `setup-debian-base` / `distribute-root-ca` / `install-unattended-upgrades` / `install-alloy` / `install-smartctl-exporter`) all applied with no per-host playbook needed. Metrics + logs flowing to Grafana Cloud while gondor is down. Foundation for the Pi-as-always-on-companion proposal; SSD/Ethernet/k3s/Pi-hole/Headscale/watering still deferred under that proposal.
- **Mirror metrics + logs to Grafana Cloud free tier** — host-alloy + k-p-s Prom dual-export with curated allowlists; ~3,100 of 10k series. Same JSON imports cleanly into both Grafanas via `$datasource` parameterization.
- **Hardware status dashboard (SMART + hwmon)** — `smartctl_exporter` on earendil, `homelab-hardware` Grafana dashboard for disk health + CPU/PCH temps.
- **Per-deployment workload dashboard** — `homelab-workload`, namespace + deployment-scoped utilization vs requests/limits + pod state + scoped Loki logs.
- **Flux observability dashboard in Grafana** — `homelab-flux`, gotk_resource_info-driven per-resource state plus reconcile rate/latency/errors.
- **Loki + journald shipping** — Phase 2 of observability stack; Alloy → in-cluster Loki via `loki.source.journal`, basic-auth at the Traefik edge.
- **Manage Samba config in ansible** — `manage-samba-config.yaml` templates `/etc/samba/smb.conf` from `host_vars/smb.yaml`; `testparm` validation before reload.
- **Manage NFS exports in ansible** — `manage-nfs-exports.yaml` templates `/etc/exports` from `host_vars/nfs.yaml`; idempotent re-runs.
- **CloudNativePG operator** — Postgres platform on gondor; underpins Immich, available for future stateful apps.
- **Immich** — deployed; ML enable still pending (see active entry above).
- **Jellyfin** — deployed.
- **Pseudo users + sudo on root-only hosts** — `setup-pseudo-user.yaml`; SSH switched from root → pseudo with NOPASSWD sudo.
- **`nfs-common` install — generalize beyond k3s** — folded into the planned onboarding-playbook entry.
- **`tirion-root-ca` Secret cleanup** — one-off cleanup, completed.
