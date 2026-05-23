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

### Dashboard query parity audit (Grafana Cloud allowlist mismatches)

The recent dashboard parameterization (`$datasource` variable from commit `d71ac18`) makes one dashboard JSON work against both the in-cluster Prom (full cardinality) and Grafana Cloud Prom (curated allowlist via `templates/config.alloy.j2`'s `grafana_cloud_keep` relabel). But the same JSON can have different *behavior* per datasource if a panel's PromQL filters on labels the cloud side drops.

**Known case**: `homelab-host-overview` CPU panel queries `node_cpu_seconds_total{...,mode!="idle"}` — the cloud allowlist drops every CPU mode except idle (intentional for cardinality), so the panel returns "No data" on the cloud view for every host. Fix: rewrite to the standard idle-complement formula, which works on both:

```promql
100 - avg(rate(node_cpu_seconds_total{instance="$host",job="integrations/unix",mode="idle"}[$__rate_interval])) * 100
```

**Broader audit needed**: walk every panel in `gondor/apps/observability/dashboards/*.json` against the allowlist + drop rules in `templates/config.alloy.j2` (lines 73-107). Specifically check for queries that filter `mode`, `fstype`, or `device` with regex/inequalities — those are the three labels we drop on. Other panels in `homelab-host-overview` looked OK on a quick read, but `homelab-hardware`, `homelab-flux`, and `homelab-workload` haven't been spot-checked end-to-end against the cloud view.

Probably 30-60 min: open each dashboard on the Grafana Cloud side with a known-online host selected, identify any "No data" panels, fix the queries to be allowlist-compatible, re-`just dump-grafana` (or whatever the export ritual is), commit.

### smartctl_exporter — exclude non-SMART-capable USB drives

`install-smartctl-exporter.yaml` configures the exporter with `--smartctl.rescan=10m` and no device filter, so it tries to read SMART from *every* block device. USB-attached drives whose enclosure bridges only do minimal SAT pass-through (e.g. Seagate Expansion Portable, the SRD0NF1 family) can't return an ATA IDENTIFY structure through the bridge, so the exporter logs a `device not found` triple every scrape interval (~once per minute) into journald. Currently visible on samwise once the 2TB Seagate is attached as a USB drive — three log lines per minute, forever, ~4,300/day.

Two clean fixes, pick one when convenient:
- **Per-host exclude list**: extend `install-smartctl-exporter.yaml` to template a host-specific `--smartctl.device-exclude=<glob>` (or repeated `--smartctl.device=<allowlist>` flags) sourced from `host_vars/<host>.yaml`. Most flexible; lets earendil keep scanning everything while samwise excludes its USB drive.
- **Auto-detect on probe failure**: smartctl_exporter has no native "auto-skip-on-failure" flag, but a wrapper script could probe each device once at startup and pass only the responsive ones via `--smartctl.device=`. More work; less config drift.

Tracking-wise: prefer the per-host exclude list for now (smaller change). Surfaces from the samwise+Seagate combination but applies generally to any USB-attached drive whose bridge fails ATA IDENTIFY.

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

### Re-add EssentialsX to eregion when Paper-26 compat lands

EssentialsX 2.21.2 (latest stable as of May 2026) crashes on enable against Paper 26.1.2 — `NullPointerException` from its `ServerStateProvider` lookup, which is a Paper-26 API change. The `2.22.0-dev` snapshots on `ci.ender.zone` predate Paper 26.1.2's release by a few days so they don't have the fix either. Dropped from `host_vars/eregion/main.yaml`'s `paper_plugins:` for now; Multiverse-Core covers the multi-world need and vanilla `/gamemode`, `/tp`, `/give`, `/time set`, `/weather`, etc. cover the basic admin needs on a 1-2 player server.

Watch [EssentialsX/Essentials releases](https://github.com/EssentialsX/Essentials/releases) for a 2.22.0 (or later) stable release marked as Paper-26-compatible, then add it back via the standard `paper_plugins` shape with the new release's SHA512. If nothing lands within a couple of months and `/home`/`/spawn`/`/kit`/`/msg` start to feel missing, the alternatives are smaller-scoped plugins (e.g. `HuskHomes`, `CMI` — both have Paper-26 builds) or just continued use of vanilla equivalents.

### Immich machine-learning enable

Immich currently runs with `machine-learning.enabled: false` to keep memory predictable while the rest of the pipeline gets validated. Flipping it on adds ~1-2 GiB of RAM (the ML container holds CLIP + face-detection models in memory) and unlocks face grouping, smart search, and content-aware tagging. Wait until the capacity rebalance below frees up the budget on gondor; the deploy itself is a one-line values change.

### Immich non-root hardening

Server pod currently runs as `runAsUser: 0` with `supplementalGroups: [10000]` for `/bulk/*` access. Both `/bulk/photos` and `/bulk/media` are mounted `readOnly: true`, so the actual blast radius is small — but there's no reason to keep root. Flip to `runAsUser: 1000` + `runAsGroup: 1000` once the external-library scans are confirmed working end-to-end. Need to verify the immich-library PVC (managed library on `nfs-scratch`, written-to) tolerates the uid change; nfs-subdir-external-provisioner directories are mode 777 by default so it should.

### CNPG cluster backups (barman → Backblaze)

The Immich Postgres cluster is currently durability-insured only by gondor's PBS snapshots — crash-consistent at best, since PBS doesn't quiesce the database. CNPG has first-class barman-cloud support; pointing it at the Backblaze bucket aglarond already uses gives application-consistent base backups + continuous WAL archiving. Pre-flight: confirm aglarond's Backblaze creds are valid via a no-op `restic check` first, otherwise debugging happens during the wrong session. Configuration lives on the `Cluster` CR (`spec.backup.barmanObjectStore`) plus a `ScheduledBackup` CR for the cadence. Applies cluster-wide, not just to Immich — any future CNPG cluster benefits.

### Auto-watering on samwise (k3s workload + GPIO)

Plant watering as a Flux-reconciled k3s workload on samwise (ARM worker — joined, tainted `NoSchedule`; Deployment will need a toleration + nodeSelector). Hardware: relay board + solenoid valve(s) + power on the Pi side; software: small Python container (gpiozero/libgpiod) wrapped in either a Deployment-with-internal-scheduler or a CronJob — the choice depends on how the gondor-nightly-downtime constraint resolves.

**Real design questions for the implementing session:**
- **GPIO passthrough into the pod**: privileged pod or specific device mounts (`/dev/gpiochip0`, `/dev/gpiomem`, `hostPath` for `/sys/class/gpio`). Privileged is simpler; mounts are more correct.
- **Gondor-down constraint**: CronJobs are scheduled by the k3s controller-manager on the server (gondor) — when gondor is down nightly, CronJobs don't fire. Three options to weigh:
  1. Restrict watering to gondor's daytime uptime window only (simplest)
  2. Deployment with internal Python scheduler that fires GPIO on its own clock — survives gondor outage as long as samwise is up (most robust)
  3. Belt-and-suspenders native systemd timer fallback if the k8s side missed its window (overkill for v1)
- **Image source**: ARM64 Python container — manual `docker buildx` to start, eventually built by self-hosted GHA runners (see CI/CD section).

Time-pressured by growing season. Samwise is a k3s worker now; the remaining gate is the USB SSD swap (needed before any local-path PV gets written to SD-card flash) + relay/solenoid hardware on the Pi side.

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
3. Apply via Terraform — bump `memory.dedicated` (and `cpu.cores` if relevant) in the guest's `terraform/*.tf`, then `just tf apply`. PVE UI works too but TF is the source of truth now.
4. Re-run `just dump-pve-configs` to capture the new shape
5. Reallocate the freed RAM to gondor — gives ML headroom on Immich and breathing room for future apps

~30-45 min once the targets are clear.

## Network & DNS

### Pi-hole / AdGuard for local DNS

Right now `vingilot.internal` records live on the Verizon CR1000A router. Adding any new internal hostname requires a manual A-record on the router *before* cert-manager can complete its HTTP-01 self-check (see [project memory](../.claude/projects/-Users-pseudo-repositories-homelab/memory/project_dns.md)).

A local resolver (Pi-hole or AdGuard Home) deployed as a HelmRelease on samwise (k3s ARM worker — joined, tainted `NoSchedule`; HelmRelease will need a matching toleration + nodeSelector) unlocks wildcard `*.vingilot.internal → 192.168.1.220` and removes the per-service DNS friction. Persistent gravity DB on local-path-provisioned PV (samwise's USB SSD) so the resolver survives gondor's nightly shutdown. Bootstrap-order mitigation: samwise's own `/etc/resolv.conf` points at CR1000A (192.168.1.1), never at itself, so a samwise reboot doesn't deadlock kubelet trying to pull images. CR1000A's DHCP DNS option points at samwise → LAN clients use Pi-hole. Probably a 1-2 hour session — gated on the SSD swap so we have a non-SD PV target.

### Headscale / Tailscale for remote access

Mesh VPN replaces per-service Cloudflare Tunnels for SSH and admin access — every device on the tailnet gets a stable address regardless of where it physically is, and homelab services that don't need public exposure can stay tailnet-only. Deploys as a HelmRelease on samwise (k3s ARM worker — joined; HelmRelease will need a toleration for the `NoSchedule` taint + nodeSelector + persistent SQLite control DB on local-path PV); pod survives gondor's nightly shutdown as long as samwise stays up. Gated on the SSD swap for the PV.

Two related capabilities to layer in once the coordinator is up:
- **Tailscale subnet router**: announce `192.168.1.0/24` so the whole LAN is reachable through one node — no per-LXC client install.
- **WoL bridge**: a small HTTP service on the tailnet that wakes earendil via magic packet from anywhere (described in the Pi-orchestrator entry).

## Specific upgrades

### erebor (PBS) trixie upgrade

PBS 3 → 4 follows its own ritual; deferred until summer 2026 since PBS 3.x has security support through August. Inherently risky because erebor is the backup target — if the upgrade goes badly, restoring relies on the system you're upgrading. Snapshot first.

**Verify after upgrade**: `zfs-zed.service` is currently in a restart loop on PBS 3.x (visible in Loki: `Failed with result 'exit-code'` + `Scheduled restart job, restart counter is at 1006`). PBS 4 ships newer OpenZFS (2.3.x vs 2.2.x) and may resolve this. If it still flaps after the upgrade, investigate as a standalone issue.

### Alloy on erebor

Pending erebor's trixie upgrade — Alloy via the Grafana apt repo wants newer libc than PBS 3 ships. Once that's done, erebor joins the alloy fleet.

### Anduril → direct HDMI to the living-room TV

The Samsung CU7000 + moonlight-tizen client is the ceiling for couch streaming — entry-level SoC + a community web-app port. The Mac (native client) is flawless from the identical host even with the TV on wired Ethernet, so it's purely client-side. Plan: run a **fiber-optic HDMI cable** (~50 ft AOC, directional) from earendil's GTX 970 straight to the TV so it becomes a real display — zero encode/decode, no Tizen. Coexists with Sunshine (the TV replaces the dummy plug; Sunshine still captures it for the Mac). Open pieces: (1) **input** — earendil has NO Bluetooth, so a controller dongle (PS5 DualSense over BT, or the Steam Controller 2 2.4 GHz dongle) needs a **USB extender** to sit at the couch end, passed through best-effort `host=VID:PID`; (2) **EDID** — connect before boot (a live modeset wedges the card), and keep the dummy plug / an EDID retainer so anduril always has a display target when the TV is off. Pays off fully once the Steam Controller arrives.

### Anduril cleanups: qemu-guest-agent + 32-bit NVIDIA libs

- **qemu-guest-agent** isn't installed/running in the Kubuntu guest (the vzdump log shows `agent configured but not running`; it's why graceful `qm shutdown`/`qmreboot` time out and we fall back to hard `qm stop`). `apt install qemu-guest-agent` + enable → graceful shutdown + fs-frozen (consistent) backups. The TF already has `agent { enabled = true }`, so this just closes the host/guest mismatch.
- **32-bit NVIDIA lib mismatch**: `libnvidia-*-580:i386` at **580.159.03** (apt) is installed alongside the `.run` **580.95.05** 64-bit driver — a version skew that can break 32-bit GL apps (old Proton games / some emulators). Fix: remove the apt i386 nvidia libs and re-run the `.run` with `--install-compat32-libs` so the 32-bit libs match.

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

## Cleanup

### Converge ansible drift surfaced during eregion onboarding

Running `--check --diff` unrestricted previews of the baseline plays before adding eregion turned up real drift on the existing fleet — `-l eregion` had to be used because of it. Two specific items:

- **`install-alloy.yaml` config template drift**: the in-repo `templates/config.alloy.j2` differs from what's deployed on `aglarond`, `earendil`, `erebor`, `nfs`, `smb`, `tirion`. Each shows `changed=2` (template task + handler restart) on a preview. Means the template was edited at some point and the play hasn't been re-run unrestricted since. Fix: just run `ansible-playbook ansible/playbooks/install-alloy.yaml` unrestricted. Quick.
- **`setup-debian-base.yaml` drift**: `Set system default locale` shows `changed` on 4 hosts (locale file content differs), and `Set system timezone` shows `changed: [erebor]` (community.general.timezone normalizing `Etc/UTC` → `UTC` — cosmetic but listed for completeness). Same fix: run `setup-debian-base.yaml` unrestricted.

Per `feedback_playbook_unrestricted_safety.md`, untargeted hosts should always show `changed=0` on a preview. Drift is the cost of not re-running unrestricted plays between edits; a periodic convergence pass keeps the rule honest.

### Re-document PVE guest configs after recent ansible work

The embedded `# ...` comment blocks at the top of several `/etc/pve/lxc/*.conf` files document procedures that are now superseded by ansible playbooks:

- **`120.conf` (nfs)** — "Adding an export" section uses `cat >> /etc/exports`. Now obsolete: `manage-nfs-exports.yaml` templates the file from `host_vars/nfs.yaml`.
- **`121.conf` (smb)** — same shape: "Adding a share" via `cat >> /etc/samba/smb.conf`. Now obsolete: `manage-samba-config.yaml`.

Recommended fix: edit the live `/etc/pve/lxc/120.conf` and `/etc/pve/lxc/121.conf` via the Proxmox UI's notes editor (or `vim` on earendil) to trim the obsolete sections and replace with one-liner pointers to the ansible playbooks. Then re-run `just dump-pve-configs` to refresh the local snapshot. Other config notes (PBS bootstrap on erebor, restic on aglarond, idmap on smb, bind-mount strategy) remain accurate.

### Migrate bpg resource names from `proxmox_virtual_environment_*` to `proxmox_*`

The bpg/proxmox provider is renaming its resources to drop the `virtual_environment_` prefix — flatter names, and the old names are slated for removal in bpg v1.0. Phase 2.5 used the new names for the storage/cluster_options resources it added. The existing guest resources still need migration:

- **2 VMs (`gondor`, `anduril`)** — *unblocked*: `proxmox_vm` exists. Procedure per resource: `tofu state mv proxmox_virtual_environment_vm.<name> proxmox_vm.<name>`, then update the resource type in the corresponding `.tf` file, then `just tf plan` to confirm no-op.
- **5 LXCs + eregion** (`aglarond`, `erebor`, `nfs`, `smb`, `tirion`, `eregion`) — *blocked*: bpg hasn't published `proxmox_container` yet. Watch bpg release notes; when it lands, same `state mv` procedure as the VMs.

After all migrations land, `just tf plan` stops emitting the "Deprecated — use ... instead" warnings. No functional change either way.

### Add PVE Notes-tab descriptions for tirion, eregion, gondor

Three guests have empty descriptions in PVE's Notes tab:

- `tirion` (CT 141) — step-ca / internal CA
- `eregion` (CT 142) — PaperMC Minecraft server
- `gondor` (VM 140) — k3s + Flux cluster

The other guests (aglarond, erebor, nfs, smb, anduril) all have substantive Notes blocks visible in the PVE sidebar and now mirrored as `terraform/descriptions/*.md` sidecar files loaded via `description = file(...)`. Filling in the missing three brings the fleet to parity. Write the descriptions directly in PVE's Notes editor (markdown), then `just dump-pve-configs` to refresh the snapshot, then save them as `terraform/descriptions/{tirion,eregion,gondor}.md` and reference from each resource — same pattern as the existing five.

### Clarify earendil storage location naming

Five storage entries appear in PVE's sidebar — `local`, `local-zfs`, `main`, `backups`, `scratch-zfs` — and from the names alone it's hard to remember which is which:

- **`local`** (dir on `/var/lib/vz`) — auto-created by PVE installer. Holds ISOs, templates, CT root volumes only if non-ZFS. Largely unused on this host.
- **`local-zfs`** (zfspool on `rpool/data`) — auto-created by PVE installer. Default VM/CT disk storage.
- **`main`** (PBS storage on `erebor.vingilot.internal`) — chunk-level backup target. Name doesn't reflect that it's PBS or that it lives on a remote host.
- **`backups`** (dir on `/scratch/backups`) — local vzdump target on the scratch ZFS pool. Coexists confusingly with `main` which is also backup-targeted.
- **`scratch-zfs`** (zfspool on `scratch`) — image/rootdir storage on the scratch pool, for things that don't need rpool durability.

Better names would make the purpose obvious from the sidebar — e.g. `local-iso` for the dir, `pbs-erebor` for the PBS storage, `vzdump-local` for the local backup target. Renaming is non-trivial: storage IDs are referenced by every guest disk (`local-zfs:vm-140-disk-1` etc.), and changing them means updating every disk pointer + restarting guests. Worth scoping the blast radius before doing it; a documentation-only pass (e.g. README table mapping name → purpose) is the lower-effort alternative if renaming proves too disruptive.

## Generalize / refactor

### Terraform-side improvements for fresh LXC bootstrap

Two paper-cuts surfaced when standing up `eregion` (CT 142) — both fixable in the TF layer so the next fresh LXC is friction-free:

- **SSH-key injection at create**: a freshly-Terraformed LXC has no `pseudo` user and no SSH key on root, so `setup-pseudo-user.yaml` (which wants to SSH as `pseudo`) can't run against it until someone manually `pct exec`'s a key into `/root/.ssh/authorized_keys` from earendil. bpg's `initialization.user_account.keys` block (`keys = [chomp(file(pathexpand("~/.ssh/id_ed25519.pub")))]`) sets `root`'s authorized_keys at container creation — eliminates the manual bootstrap step. Add to every LXC resource in `terraform/*.tf` (one-liner each).
- **Static IPs fleet-wide**: `eregion.tf` was migrated to `address = "192.168.1.42/24"` + `gateway = "192.168.1.1"` after we hit DHCP-reservation drift (IP-pinned in router DNS but the LXC pulled a different lease). The other 5 LXCs (`nfs` .200ish, `smb`, `erebor`, `aglarond`, `tirion`) still use `address = "dhcp"` and rely on router-side MAC reservations. Backport their actual current IPs into TF and drop the router-side reservation — keeps the IP source of truth in one place (and dovetails with the eventual pihole/adguard TF, where DNS records will reference the same numbers).

Both are mechanical edits to existing `.tf` files; ~15 min once. `just tf plan` should be no-op after each backfilled-IP change since the IP doesn't actually move.

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

### Pi promoted to k3s control plane (Phase 2)

Phase 1 (samwise as ARM-tagged k3s worker hosting Pi-hole, Headscale, watering as Flux-reconciled workloads) is now decided — see the concrete entries above (Pi-hole / AdGuard, Headscale, Auto-watering on samwise). The remaining open question is whether to eventually promote samwise to k3s control plane.

Driver: earendil shuts down nightly, so the k3s server (gondor) is unreachable ~12h/day. Worker pods on samwise survive (kubelet caches state) but the **controller-manager is on the server side**, so CronJobs don't fire when gondor is down — biggest concrete pain in the worker-only model. Promoting samwise to control plane resolves "API server gone overnight" — CronJobs fire, Flux reconciles, `kubectl` works at 3am.

Heavier migration: relocate gondor's local-path PVs to samwise (or to NFS), re-bootstrap flux-system at the new endpoint, switch every kubeconfig to the Pi address. ~2-4h planned outage. Trust the Pi to host etcd/SQLite writes 24/7 (USB SSD non-negotiable; Pi 5 boots from USB natively in 2026).

Worth doing if/when the worker-only limitations are concretely felt — don't preemptively pay this cost. Most likely trigger: a CronJob that genuinely needs to fire overnight and isn't a fit for the "Deployment with internal scheduler" workaround.

**Open questions before this graduates from proposal:**
- **Cost-justified?** Depends on the Kill-A-Watt measurement above. If earendil idles at 60W with the GTX 970 holding power, nightly shutdown saves more and the Pi pattern earns its place financially. If it idles at 35W, the savings are thin and the Pi becomes pure operational-leverage / learning play (still legitimate — over-engineering for learning is the point of the homelab).
- **One Pi or two?** Orchestrator wants "next to the switch with wired link"; watering wants "near the plants." A dedicated cheap Pi (Pi 4 / Zero 2 W) for plants is the obvious resolution if those goals conflict.
- **CR1000A as DNS fallback.** Router can hand out a secondary DNS — useful safety net for "Pi failed at 2am," but the leak-through behavior on Windows/Linux clients (clients sometimes prefer/cache the secondary) isn't great.

---

## Completed

Reverse-chronological — most recent first. One line each; `git log` carries the rest.

- **Anduril replatformed to Kubuntu 26.04 LTS** — retired Bazzite (which dropped Sunshine from its base image — an unfixable atomic-distro mismatch). anduril now joins the standard Debian fleet bootstrap via `site-anduril.yaml` (pseudo user, base, **distribute-root-ca**, unattended-upgrades, **Alloy**, Sunshine) — closing the "Anduril Alloy + distribute-root-ca rollout" item, whose only blockers were the OS-family branching that vanished with apt. `setup-sunshine.yaml` rewritten Debian-side: GTX 970 NVENC via the **580.95.05 `.run` driver on a mainline 6.12.90 kernel** (apt 580.159 + stock 7.0 both hang the display engine — manual bring-up, captured in the PBS snapshot), `nvidia-drm.modeset=1`/simpledrm-blacklist cmdline, the proper `nvidia-persistenced` unit, and a **`kde-inhibit` keep-awake service** (a DPMS-off/wake cycle corrupts KMS capture until a host reboot; powerdevil's config proved unreliable on Plasma 6.6). cores bumped 4→6. Hard-won lesson: never hot-change the display mode on a live session — a `kscreen-doctor` modeset wedges the card, and with no PCI reset only a host reboot recovers it.
- **GPU passthrough host-side prereqs codified** — `setup-vfio-passthrough.yaml` lifts the IOMMU cmdline, vfio modules in `/etc/modules`, NVIDIA blacklist, and vfio-pci PCI ID binding (parameterized via `vfio_passthrough_ids`, default `10de:13c2,10de:0fbb` for the GTX 970 + HDMI audio) out of operator notes. Token-merge for the kernel cmdline preserves ZFS-root + other tokens; handlers chain `update-initramfs` + `proxmox-boot-tool refresh` only on change. `site-earendil.yaml` introduced alongside, mirroring `site-anduril.yaml`'s wrapper pattern (imports pin-kernel + vfio + terraform-pve-access). Reboot left to a human decision since it drops every guest.
- **PaperMC server on `eregion` (CT 142)** — new unprivileged Debian 13 Trixie LXC on earendil, provisioned via `terraform/eregion.tf` (the first TF resource born static-IP'd at .42 rather than DHCP+reservation), running Paper 1.21.11 build 69 under a hardened `paper-server.service` unit with Aikar's flags + clean `mcrcon stop` shutdown. Pinning via `host_vars/eregion.yaml`; upgrade procedure in `runbooks/paper-upgrade.md`. LAN-only at `eregion.vingilot.internal:25565`; RCON localhost-only via the host's network position + strong password (vanilla MC's `rcon.bind` is silently ignored by Paper).
- **Suppress Proxmox no-subscription nag** — `setup-proxmox-no-nag.yaml` patches the `proxmox-widget-toolkit` JS on earendil (PVE) + erebor (PBS) to flip the popup gate to `false` (regex anchored on `!res ||` so the subscription-badge check elsewhere in the file is left alone), plus a `blockinfile`-managed MutationObserver block on PVE's mobile UI template that strips subscription dialogs and cards at runtime. A `DPkg::Post-Invoke` apt hook re-runs an idempotent patch script so a future `proxmox-widget-toolkit` upgrade can't silently restore the popup; the play also cleans up pre-ansible hand-rolled nag-patch helpers.
- **`install-k3s.sh` refactored to ansible** — `install-k3s-server.yaml` is the new source of truth for gondor's k3s server install, version pinned via `host_vars/gondor.yaml`. Idempotency is layered: `systemctl is-active k3s` short-circuits the whole installer block on a live cluster, `creates: /usr/local/bin/k3s` is a second-line guard, and a version mismatch fails loud rather than silently re-installing (Flux + Immich + cnpg + Jellyfin + Traefik live on this single-node etcd, so silent re-runs are not acceptable). Worker version-lockstep with gondor stays enforced by `install-k3s-agent.yaml`'s pre-flight assert. `gondor/bootstrap/install-k3s.sh` + `just bootstrap-gondor` + the top-line `k3s_version :=` retire in a follow-up commit once the user lands the broader justfile cleanup.
- **Longer-lived ACME certs + on-boot renewal** — `install-step-ca.yaml` bumps tirion's `acme` provisioner to a 90d default/max cert lifetime (`step ca provisioner update --x509-default-dur 2160h --x509-max-dur 2160h`) with idempotent drift detection; `setup-acme-renewal.yaml` drops `RandomizedDelaySec=0` + `OnBootSec=2min` overrides onto earendil's `pve-daily-update.timer` and erebor's `proxmox-backup-daily-update.timer` so a host returning from days-of-power-off renews promptly rather than waiting for the next jittered daily window.
- **samwise joined gondor's k3s cluster as ARM worker** — `install-k3s-agent.yaml` fetches gondor's node token, appends `cgroup_memory=1 cgroup_enable=memory` to `/boot/firmware/cmdline.txt` (RPi-only, idempotent), reboots once if needed, then installs k3s-agent pinned via `host_vars/samwise.yaml`'s `k3s_version`. Worker carries `homelab.vingilot.internal/{host=samwise,role=worker}` labels and a `role=pi:NoSchedule` taint so existing amd64-only HelmReleases (Immich, Jellyfin, cnpg, Traefik, MetalLB, ...) can't be rescheduled there. Phase 1 only — SD card + WiFi; SSD/Ethernet migration + Pi-hole/Headscale/watering still queued behind it.
- **Anduril Steam Machine hardening** — `setup-bazzite-base.yaml` + `setup-sunshine.yaml` + `site-anduril.yaml` lock anduril into deliberate-upgrade mode: ostree deployment pinned, `rpm-ostreed-automatic.timer` disabled, KDE screen blanking off, sunshine env-poll dropin, `nvidia-persistenced` enabled, polkit rules for ansible-managed systemd + pseudo-managed rpm-ostree. `just patch-bazzite` is non-interactive and chains `verify-bazzite-staged` to catch critical-package removals before reboot (caught Bazzite-F44 dropping sunshine from the base image cleanly). *(Superseded May 2026 by the Kubuntu replatform above — `setup-bazzite-base.yaml` + the `patch-bazzite`/`verify-bazzite-staged` recipes are retired; kept here as history.)*
- **Proxmox kernel pin** — `pin-proxmox-kernel.yaml` writes `/etc/kernel/proxmox-boot-pin` to lock earendil to a chosen kernel and refreshes the EFI System Partitions. Needed after `proxmox-kernel-7.0.0-3-pve` introduced a vfio regression that broke GTX 970 passthrough into anduril; bumping the `proxmox_kernel_pin` variable + re-run + reboot is the deliberate upgrade flow.
- **Samwise (Raspberry Pi 5) onboarded** — added to `sudo_hosts` / `physical_hosts` / `debian_guests` / `alloy`; running RPi OS Lite Trixie (aarch64) on WiFi + SD card; baseline (`setup-pseudo-user` / `setup-debian-base` / `distribute-root-ca` / `install-unattended-upgrades` / `install-alloy` / `install-smartctl-exporter`) all applied with no per-host playbook needed. Metrics + logs flowing to Grafana Cloud while gondor is down. Foundation for the Pi-as-always-on-companion proposal; SSD/Ethernet/Pi-hole/Headscale/watering still deferred under that proposal (k3s join itself landed separately — see entry above).
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
