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

### SSH from iPhone over the tailnet

Now that the iPhone reaches the fleet over the tailnet (see the native-`tailscaled` entry in Completed), make it a first-class SSH client. Generate the keypair *on the phone* in the SSH app (Blink Shell / Secure ShellFish / Termius / Prompt) and keep the private key in the Secure Enclave where the app supports it (hardware-backed, non-exportable); only the **public** key ever leaves the device.

Codify it rather than hand-appending per host: `setup-pseudo-user.yaml` today installs a single operator key (`lookup('file', ~/.ssh/id_ed25519.pub)`). Small refactor — turn that into a loop over a *list* of authorized pubkeys — then commit the iPhone's `.pub` under `ansible/files/` (public keys aren't secret) and re-run the playbook fleet-wide. `exclusive: false` is already set, so the add is non-destructive to keys already present on a host.

Reaching hosts by `*.vingilot.internal` name from the phone needs Tailscale split-DNS (point that domain at the CR1000A — or Pi-hole once it lands, see Network & DNS); until then, connect by tailnet/LAN IP. Pairs with the **iOS device trust** item (root CA) for a complete "iPhone as homelab client" story.

Alternative considered: **Tailscale SSH** (deliberately left off when Tailscale shipped) auths by tailnet identity + an ACL `ssh` rule and sidesteps key distribution entirely — but the iOS Tailscale app can't originate `tailscale ssh`, so you'd still drive it from a third-party SSH app pointed at the tailnet IP (the host intercepts the session). Worth revisiting if per-device key management becomes a chore.

### Pre-commit hook in a durable dotfiles repo

The private-key-marker pre-commit hook lives at `~/.config/git/hooks/pre-commit` on thorondor. Should be tracked somewhere — chezmoi-style dotfiles repo would be the natural home. "Future weekend" project.

### Kyverno — admission-time enforcement of the house conventions

CI now validates what is *in git* (encryption, pins, build validity); nothing enforces runtime conventions at admission — resource requests/limits on every workload, no `:latest` images, the per-app-namespace pattern. Kyverno as a HelmRelease closes that gap and completes the arc: validated in CI, enforced at admission (a stray `kubectl apply` cannot dodge it).

Roll out audit-first: policies in `Audit` mode, PolicyReports reviewed via Grafana, then promote the few worth hard-enforcing to `Enforce`. Audit-first matters on a one-person cluster — enforce-mode can fight you mid-incident, and the report data shows which rules would actually fire before anything blocks.

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

**Broader audit needed**: walk every panel in `kubernetes/apps/observability/dashboards/*.json` against the allowlist + drop rules in `templates/config.alloy.j2` (lines 73-107). Specifically check for queries that filter `mode`, `fstype`, or `device` with regex/inequalities — those are the three labels we drop on. Other panels in `homelab-host-overview` looked OK on a quick read, but `homelab-hardware`, `homelab-flux`, and `homelab-workload` haven't been spot-checked end-to-end against the cloud view.

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

### Network status tester

A little Go pod running as a cronjob that starts up, runs a network speedtest for upload/download rate, then saves that 
do a DB which is added to a data source in grafana.  Cadance TBD, but I'm thinking once an hour.  goal is to gather data 
on how my network performance is over time so I can feel justified in my disdain for verizon

Earendil's nightly shutdown complicates this.  could run it on samwise, but it'd have to be a persistent pod instead of a 
cron because we lose the control plane every night.  but might be fine if this is a little 25mb pod

Could also run it as a daemon set and have the pods do leader election so that they don't run their tests at the same time. 
then we have data per node.  would want the pod to check and make sure the node's link isn't already saturated so that they 
don't run at a time when other high network bandwidth tasks are running

### Re-add EssentialsX to eregion when Paper-26 compat lands

EssentialsX 2.21.2 (latest stable as of May 2026) crashes on enable against Paper 26.1.2 — `NullPointerException` from its `ServerStateProvider` lookup, which is a Paper-26 API change. The `2.22.0-dev` snapshots on `ci.ender.zone` predate Paper 26.1.2's release by a few days so they don't have the fix either. Dropped from `host_vars/eregion/main.yaml`'s `paper_plugins:` for now; Multiverse-Core covers the multi-world need and vanilla `/gamemode`, `/tp`, `/give`, `/time set`, `/weather`, etc. cover the basic admin needs on a 1-2 player server.

Watch [EssentialsX/Essentials releases](https://github.com/EssentialsX/Essentials/releases) for a 2.22.0 (or later) stable release marked as Paper-26-compatible, then add it back via the standard `paper_plugins` shape with the new release's SHA512. If nothing lands within a couple of months and `/home`/`/spawn`/`/kit`/`/msg` start to feel missing, the alternatives are smaller-scoped plugins (e.g. `HuskHomes`, `CMI` — both have Paper-26 builds) or just continued use of vanilla equivalents.

### Immich non-root hardening

Server pod currently runs as `runAsUser: 0` with `supplementalGroups: [10000]` for `/bulk/*` access. Both `/bulk/photos` and `/bulk/media` are mounted `readOnly: true`, so the actual blast radius is small — but there's no reason to keep root. Flip to `runAsUser: 1000` + `runAsGroup: 1000` once the external-library scans are confirmed working end-to-end. Need to verify the immich-library PVC (managed library on `nfs-scratch`, written-to) tolerates the uid change; nfs-subdir-external-provisioner directories are mode 777 by default so it should.

### CNPG cluster backups (barman → Backblaze)

Verified 2026-07-02: all four clusters (immich/harbor/keycloak/auto-water) have an **empty `spec.backup`** — the operator backs up nothing — and every PG PVC is on `nfs-scratch`, so the actual bytes live on earendil's scratch pool *outside* gondor's PBS image. Real protection today is whatever covers the scratch dataset: filesystem-level, crash-consistent for a live database, and short-horizon since the 3d/2w retention trim. Higher urgency than this entry originally implied.

Barman-cloud ships base backups + a continuous WAL archive straight from the postgres pods to B2's S3 endpoint (aglarond/restic uninvolved — parallel streams). Use a **separate bucket + bucket-scoped application key** so the in-cluster credential can't touch the restic repo and vice versa; both tools manage their own object lifecycle — never share a prefix. Encryption: TLS in transit + SSE-B2 at rest (`data.encryption`/`wal.encryption: AES256`); that's server-side (B2 holds keys), unlike restic's client-side model — if key custody matters, complement with a low-cadence `pg_dump` CronJob into a restic-covered path. Config: SOPS Secret for the key, per-`Cluster` backup stanza + `ScheduledBackup`, `retentionPolicy` sized to the bucket. Pre-flight per the verify-docs rule: recent CNPG releases are migrating from in-tree `spec.backup.barmanObjectStore` to the Barman Cloud CNPG-I plugin — confirm which shape the running operator wants. Applies cluster-wide; WAL archiving takes RPO from "last snapshot" to minutes.

### Auto-watering on samwise (k3s workload + GPIO)

Plant watering as a Flux-reconciled k3s workload on samwise (ARM worker — joined, tainted `NoSchedule`; Deployment will need a toleration + nodeSelector). Hardware: relay board + solenoid valve(s) + power on the Pi side; software: small Python container (gpiozero/libgpiod) wrapped in either a Deployment-with-internal-scheduler or a CronJob — the choice depends on how the gondor-nightly-downtime constraint resolves.

**Real design questions for the implementing session:**
- **GPIO passthrough into the pod**: privileged pod or specific device mounts (`/dev/gpiochip0`, `/dev/gpiomem`, `hostPath` for `/sys/class/gpio`). Privileged is simpler; mounts are more correct.
- **Gondor-down constraint**: CronJobs are scheduled by the k3s controller-manager on the server (gondor) — when gondor is down nightly, CronJobs don't fire. Three options to weigh:
  1. Restrict watering to gondor's daytime uptime window only (simplest)
  2. Deployment with internal Python scheduler that fires GPIO on its own clock — survives gondor outage as long as samwise is up (most robust)
  3. Belt-and-suspenders native systemd timer fallback if the k8s side missed its window (overkill for v1)
- **Image source**: ARM64 Python container — manual `docker buildx` to start, eventually built by self-hosted GHA runners (see CI/CD section).

Time-pressured by growing season. **The sensing half shipped** (sensors → CNPG → Grafana, live on samwise — see Completed); this entry now tracks the *actuation* half. Remaining gate: relay/solenoid hardware on the Pi side, plus the USB SSD swap before any local-path PV writes to SD-card flash.

### hamfast — recovered Pi 2 as a standalone (non-k3s) remote-plant node

The **original v1 watering Pi** resurfaced 2026-05-24 — and it's a **Raspberry Pi 2 Model B v1.1**, not the Pi 3 it was remembered as: BCM2836, **ARMv7 32-bit** (cannot run arm64), quad-core A7, 1 GB RAM, Edimax USB WiFi, 40-pin header. Found with the original 8-channel SONGLE opto-isolated relay + resistive sensors still wired (and the long-lost soldering kit).

**Decision: onboard it as a standalone ansible-managed host, _not_ a k3s worker.** The k3s agent (~300–500 MB) stacked on the host Alloy we already run everywhere (~300 MB) is unjustifiable on 1 GB for a single pinned, can't-reschedule, hand-built-armhf workload — Alloy alone gives the observability without the orchestration tax. (Tainting it into a corner works but solves the wrong problem; armv7 is effectively EOL — k3s has flagged armhf for possible removal — and a k3s node churns the SD card harder than a bare service.) The same overhead that's a rounding error on samwise's 8 GB is half the box here; the arithmetic inverts. When it's actually onboarded it earns the name **`hamfast`** (the Gaffer — Sam's father, fitting companion to samwise).

**Candidate role:** a remote / awkward-spot plant monitor-waterer running the same `auto_water` Python app from a venv + systemd unit (armhf from source, not the arm64 container samwise pulls), writing to the **same CNPG Postgres** as samwise — the `readings` table already keys on `sensor_id`, so a second node is free in the data model. samwise stays the main plant; hamfast is whenever a second plant in an odd spot materializes. No rush.

**Open design thread (multi-node → DB):** hamfast can't use cluster-local DB access, which nudges toward fronting CNPG with a **small ingestion service** both nodes write through — samwise via in-cluster Service DNS, hamfast over the LAN / Tailscale tailnet (or a MetalLB LoadBalancer). Clients then hold an API token instead of DB creds and don't couple to the schema, and it's a natural home for future watering-command APIs. Leaning gRPC (doubles as a learning goal). The app's `ReadingSink` abstraction makes the client side a drop-in (add a gRPC sink alongside the Postgres/stdout ones). A queue (Kafka/etc.) in between was weighed and rejected as overkill for one low-rate sink — NATS JetStream would be the lighter pick if durable buffering is ever wanted, but the poller already has an in-memory retry buffer.

### Durable on-disk retry buffer for auto-water (post-SSD)

The poller's retry buffer — readings held while the CNPG sink is unreachable (gondor's nightly downtime, an extended trip) — is **in-memory only** as of [auto-water#12](https://github.com/swerdick/auto-water/pull/12): a 30-day time-based window backstopped by a 1 GiB pod memory limit. It rides out a long sink outage and flushes on reconnect, **but a pod restart or reschedule drops everything buffered.** Good enough while the window is days-long and restarts are rare; not the real answer for multi-week durability.

**Plan: back the buffer with on-disk storage** — a SQLite file (or append-only WAL) on a PVC, so buffered readings survive a pod restart and the memory limit stops being the effective retention bound. Gated on the **same USB SSD swap** the samwise auto-watering entry waits on (line above): until the SSD lands, a local-path PV would write to the SD card, which is exactly the flash-wear we're avoiding. Once it's in, this is a small change behind the existing `ReadingSink`/buffer seam (the buffer becomes a durable queue the poller drains), and it composes with the gRPC ingestion service in the hamfast thread above — a remote node would want the same local durability.

### Deploy Vibeseeker to local k3s

User's own app — currently developed elsewhere, wants a stable in-cluster deployment as a real "production"-feeling target. Standard shape: HelmRelease in a `vibeseeker` namespace, HTTPRoute at `vibeseeker.vingilot.internal` (or whatever public hostname makes sense via Cloudflare Tunnel), CNPG-backed Postgres if it needs persistent state, image pulled from the local registry (see CI/CD section) or upstream until that lands. Image probably built by self-hosted GHA runners — three of the CI/CD items below are natural preconditions if the goal is full local dev-loop.

## CI/CD & developer infrastructure

### Renovate — automated dependency PRs against the CI gates

The validate workflow now gates exactly the surface Renovate feeds: 11 pinned chart ranges, pinned GitHub Action tags, three stacks of tofu provider constraints + committed lockfiles, and the sha256-pinned k3s installer. Renovate turns each upstream bump into a PR that flux-local validates *before* merge — chart values-schema breakage (the kps-major problem) gets caught in CI instead of at reconcile time.

Start with the hosted app (free for public repos, zero infra); revisit self-hosted only if the git-mirror/runners items land. Expected config work: group chart patch bumps to keep PR noise down, leave kps majors manual (its pin comment says why), and a custom regex manager for the k3s installer sha256 plus the `k3s_version` lockstep across justfile/host_vars/install script.

### Self-hosted GitHub Actions runners

GitHub-hosted runners have monthly minute caps (727 min consumed in Apr 2026 — still inside the 2000-min free tier but trending up, and the curve gets steeper as Harbor pushes + Trivy scans + SonarQube + Vibeseeker pipelines come online). They also can't reach internal homelab services without burning extra minutes via `tailscale/github-action` (~20–30s of tunnel-setup per workflow on top of the actual work). Self-hosted runners pop both ceilings at once: zero per-minute charge, direct LAN access to in-cluster registries / databases / SonarQube / Harbor with no Tailscale dance. Two viable shapes:

- **`actions-runner-controller` (ARC) in k3s** *(preferred)* — operator scales runner pods up on workflow events, down to zero between. GitHub App authentication. Most-homelabby choice; deploys via HelmRelease, plays well with Flux. Ephemeral pods are also the right security shape (fresh runner per job, no carry-over artifacts).
- **Docker-based runners on a dedicated LXC** — simpler, no scale-to-zero. Lower complexity but always-running cost.

Security: a self-hosted runner executes whatever workflow code is in the repo. Restrict via `runs-on: self-hosted` + first-time-contributor approval, and isolate runners from credential-bearing infrastructure (separate namespace, no cluster-admin). Pairs with the local registry + security scanning items below — this entry is the keystone several others depend on (SonarQube reachability, Harbor push from CI, ORAS pushes from CI).

### In-cluster git mirror as Flux's primary source

Single-failure-domain risk: GitHub disappearing (account suspension, outage, policy change) cripples Flux, which reconciles from `github.com/swerdick/homelab.git`. Distributed-git already gives free **backup** (every local clone — Mac, Flux's working copy on gondor — holds the full DAG), so this isn't about losing history. It's specifically about whether Flux keeps reconciling. Keeping GitHub public + primary for push + CI is non-negotiable; no switch to GitLab/Gitea/self-hosted GHE.

**Design — mirror as primary, not backup:**

- **k3s Deployment in `git-mirror` namespace** (not LXC). A tiny image — `openssh-server` or similar — exposes `git+ssh://` for Flux to clone from. PVC-backed bare-repo storage, NetworkPolicy locks the SSH endpoint to in-cluster traffic. Manifests live in `kubernetes/apps/git-mirror/` so Flux reconciles its own dependency (chicken-and-egg only on initial deploy, irrelevant forever after).
- **GitHub App auth, not SSH keys.** Register one fine-grained App (`Contents: Read` on the repos we mirror), mount its private key as a SOPS Secret, mint a 1h installation token at *fetch time* via JWT → `/app/installations/<id>/access_tokens` (~30-line Python helper in a ConfigMap). No long-lived token at rest in the cluster, no SSH key proliferation, revocable from the GitHub UI.
- **Flux's `GitRepository` points at the mirror by default** (not GitHub). Failure-mode story collapses: "GitHub down" becomes a non-event (mirror keeps serving last-fetched state); "mirror down" overlaps with "Flux down" since both run on gondor, an already-accepted SPOF.
- **CronJob fetches from GitHub every ~10 min** as background warmth. Smart fetch script (below) handles outage-time pushes safely.
- **`just deploy` recipe** triggers an immediate mirror fetch + `flux reconcile source git homelab` so post-push deployment latency stays sub-second (rather than the up-to-10-min cron lag).

**Smart fetch script — handles outage-time pushes without silent ref clobbering.** Naive `git fetch --mirror` is `+refs/*:refs/*` (force) and would overwrite any direct-to-mirror pushes when GitHub recovers. Instead, per branch: compare `origin/$b` to local `$b`; if mirror is ahead, `git push origin` to catch GitHub up; if GitHub is ahead, fast-forward the mirror; if genuinely diverged (rare — requires concurrent pushes to both), refuse and page. Three-way safe.

**Justfile recipes, no runbook** (per the no-low-frequency-runbooks principle):
- `just deploy` — immediate mirror fetch + flux reconcile after a push.
- `just mirror-failover-to-github` — patch `GitRepository` URL to `github.com` when the mirror itself is broken. Code is the runbook; idempotent.
- `just mirror-failback-to-mirror` — patch it back when the mirror is healthy again.

(Forgejo / a real forge with a UI was an earlier shape for this entry — explicitly out of scope after the no-Gitea-style-forge call. Revisit only if the no-UI cost ever becomes annoying.)

### Security scanning — CI-side (Trivy)

Registry-side Trivy **shipped with Harbor** (bundled scanner, `trivy.enabled: true` — auto-scans every pushed image, CVE counts per repo/tag in the Harbor UI). Remaining is the **CI-side**: `aquasecurity/trivy-action` in GitHub Actions to scan images before they're pushed (pairs with self-hosted runners). Threshold gates (fail build on HIGH+ CVEs) come later; first goal is "we can see CVE counts at all."

### Harbor Helm chart mirroring

Follow-up to image proxying above. Harbor's proxy-cache only fronts OCI registries — most chart upstreams (Jellyfin, Immich, kube-prometheus, traefik, harbor itself) still publish via traditional ChartMuseum-style HTTP repos that Harbor can't proxy, so the only path is **mirror-by-push**: `helm push oci://harbor.vingilot.internal/charts/<name>` per version, then flip each Flux `HelmRepository` to `type: oci` pointing at Harbor. OCI-native chart sources (Bitnami, growing minority) skip the push step.

**Shape:** likely a CI job (post the self-hosted-runners item above) that diffs Flux's referenced chart versions against what's in Harbor and `helm push`es the gap. Until that exists, the manual flow is fine — charts are pulled far less often than images (once per version bump, not per pod restart), so the failure-mode payoff is smaller and there's no rush.

**End state:** every chart Flux reconciles is served from Harbor; combined with image proxying, a full Flux reconcile survives total upstream-registry outage.

### Harbor + ORAS for critical loose binaries (Minecraft jars, etc.)

A handful of setup scripts pull "loose" binaries — Paper / Purpur server jars, plugin jars, mod jars — directly from upstream URLs (PaperMC's CDN, GitHub release assets). Each is a silent supply-chain dependency that breaks a host bootstrap if the URL changes or vanishes, and they get no scanning even though Trivy speaks Java archive perfectly well. ORAS (OCI Registry As Storage) pushes arbitrary blobs as OCI artifacts; Harbor accepts ORAS pushes and Trivy scans the result the same as a container image.

Workflow: catalog the critical binaries the playbooks actually reference; `oras push harbor.vingilot.internal/minecraft/paper:1.21.1 paper-1.21.1.jar` for each (one-off or via a small refresh-cron CI job); teach the playbooks to pull from Harbor with the upstream URL kept as a documented fallback comment. Pinning happens via the artifact tag; rotation happens by running the refresh job.

### Self-hosted SonarQube for static analysis

Static-analysis side of the quality/security story (Trivy covers CVEs; SQ covers code smells / bugs / coverage / duplications). Community Edition is free, Helm-installable, Postgres-backed — extends the existing CNPG operator pattern. Primary consumer is GitHub Actions on this repo + future personal projects, via `sonarsource/sonarqube-scan-action`; PR-comment integration surfaces issues at review time.

Lands after self-hosted runners — cloud-runner access would need Cloudflare Tunnel or a Tailscale-action burn that ARC sidesteps entirely. Auth: local admin only at first (CE doesn't ship OIDC; SAML works but isn't worth the wiring for one user), Keycloak deferred until Developer Edition or a CE workaround is justified.

Resource cost is the gotcha: ~3-4 GiB RAM for the SQ server idle, plus CPU spikes during analysis. Lands after the gondor capacity rebalance, or runs as a dedicated PVE LXC if it doesn't fit in k3s.

## Capacity & resource management

### Audit guest CPU/memory + rebalance

Some guests are over-provisioned. Per the host-overview dashboard:
- gondor is at 20 GiB and Immich's ML container is now enabled (server limit bumped to 6Gi — see Completed); it has comfortable headroom, so gondor itself is fine. This audit is really about the *over*-provisioned guests below
- LXCs allocate 1 GiB each, peak usage in the 150-300 MiB range
- Total host RAM is now 48 GiB (upgraded from 16 — see Completed); the hard ceiling is gone, so this is right-sizing hygiene rather than relieving real pressure

Steps:
1. Sample memory usage on each guest over a representative window (include a backup run for erebor, streaming activity for media-using guests, an Immich library scan)
2. Identify safe shrinks (`allocated 1 GiB → peak 250 MiB → shrink to 512 MiB` style)
3. Apply via Terraform — bump `memory.dedicated` (and `cpu.cores` if relevant) in the guest's `terraform/*.tf`, then `just tf apply`. PVE UI works too but TF is the source of truth now.
4. Re-run `just dump-pve-configs` to capture the new shape
5. Reallocate the freed RAM to gondor — gives ML headroom on Immich and breathing room for future apps

~30-45 min once the targets are clear.

## Resilience & recovery

### DR game day — time the fresh-rebuild flow for real

The README claims the rebuild flow (S3 state → `just tf-proxmox apply` → site playbooks → PBS/restic restore); nothing has proven it end-to-end or timed it. Run a deliberate drill — a sacrificial guest first, the full fleet on a quiet weekend if that goes well — and write down wall-clock, surprises, and gaps (likely suspects: the age-key bootstrap path, CA chain ordering, k3s join order, anything with a manual router-DNS step). Findings land as fixes plus a dated "last drill: N hours" line in the README — the single most credible durability claim the repo can make. Sequence after the CNPG barman item so the database story is part of the drill instead of a known hole.

## Network & DNS

### Pi-hole / AdGuard for local DNS

Right now `vingilot.internal` records live on the Verizon CR1000A router. Adding any new internal hostname requires a manual A-record on the router *before* cert-manager can complete its HTTP-01 self-check (see [project memory](../.claude/projects/-Users-pseudo-repositories-homelab/memory/project_dns.md)).

A local resolver (Pi-hole or AdGuard Home) deployed as a HelmRelease on samwise (k3s ARM worker — joined, tainted `NoSchedule`; HelmRelease will need a matching toleration + nodeSelector) unlocks wildcard `*.vingilot.internal → 192.168.1.220` and removes the per-service DNS friction. Persistent gravity DB on local-path-provisioned PV (samwise's USB SSD) so the resolver survives gondor's nightly shutdown. Bootstrap-order mitigation: samwise's own `/etc/resolv.conf` points at CR1000A (192.168.1.1), never at itself, so a samwise reboot doesn't deadlock kubelet trying to pull images. CR1000A's DHCP DNS option points at samwise → LAN clients use Pi-hole. Probably a 1-2 hour session — gated on the SSD swap so we have a non-SD PV target.

## Specific upgrades

### erebor (PBS) trixie upgrade

PBS 3 → 4 follows its own ritual; deferred until summer 2026 since PBS 3.x has security support through August. Inherently risky because erebor is the backup target — if the upgrade goes badly, restoring relies on the system you're upgrading. Snapshot first.

**Verify after upgrade**: `zfs-zed.service` is currently in a restart loop on PBS 3.x (visible in Loki: `Failed with result 'exit-code'` + `Scheduled restart job, restart counter is at 1006`). PBS 4 ships newer OpenZFS (2.3.x vs 2.2.x) and may resolve this. If it still flaps after the upgrade, investigate as a standalone issue.

### Alloy on erebor

Pending erebor's trixie upgrade — Alloy via the Grafana apt repo wants newer libc than PBS 3 ships. Once that's done, erebor joins the alloy fleet.

### Anduril Phase 2 — k3s GPU-worker LXC (AI/ROCm) sharing the amdgpu

The gaming half of the amdgpu-sharing replatform shipped (see Completed: the gaming LXC + Sunshine, and the input resolution). The remaining half of the original vision is a **second** privileged LXC joined to gondor's k3s as a **GPU worker for AI/ROCm**, sharing the same card: `/dev/kfd` + `/dev/dri` into pods (skip the AMD device plugin), a GPU node label + taint, ROCm; cordon/drain hands the card to the gaming LXC for heavy sessions. Input-independent — unaffected by anything in the gaming-side work. Tradeoff: shared-kernel `amdgpu` trades VM isolation for simplicity (a GPU hang can wedge the host). Plan: `~/.claude/plans/squishy-humming-thunder.md`.

### Anduril emulation — reclaim staged storage (post-validation)

The native emulation stack shipped and is validated end-to-end (RetroArch / PCSX2 / Eden all
running games — see Completed), so two build-time staging artifacts can be dropped to reclaim
space on the bulk pool:

- **Legacy emulator builds** — stale portable frontends + Switch tooling (Batocera, Recalbox,
  RetroArch v1.10.1, Jan-2022 libretro cores, SAK; ~26G) archived under `Emulation/tools/_legacy/`.
  The native stack is proven, so delete to reclaim.
- **Safety snapshots** — drop `bulk/games@pre-emulation-reorg-2026-06-25` and the
  `bulk/documents@…` companion taken before the storage reorg.

Both are pure reclaim; the live `Emulation/` tree has been exercised hard (TOTK, Smash, Mario
Kart, PS2, the full RetroArch library).

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

Phase 1 (samwise as ARM-tagged k3s worker hosting Pi-hole + watering as Flux-reconciled workloads) is now decided — see the concrete entries above (Pi-hole / AdGuard, Auto-watering on samwise). Remote access shipped separately as **native `tailscaled` on samwise**, not a k3s workload (see Completed); self-hosted **Headscale** stays a possible fallback if Tailscale ever changes its free tier. The remaining open question is whether to eventually promote samwise to k3s control plane.

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

- **Anduril native emulation (EmuDeck-style, on the gaming LXC)** — `install-anduril-emulators.yaml`: RetroArch + Dolphin + PCSX2 + Eden (native, no flatpak), ROMs sorted per-system on the bulk pool, 12 codified Steam ROM Manager parsers + PCSX2/Eden controller bindings; Switch library migrated off the Steam Deck, runs keys-only (no firmware).
- **Anduril gaming LXC — Sunshine streaming + audio + desktop apps** — CT 117 (privileged Ubuntu 26.04, shared `amdgpu`) runs KWin + Steam Big Picture on the TV and streams over Sunshine/Moonlight (Vulkan encode + KMS capture), HDMI audio pinned in WirePlumber; `setup-anduril-{session,xrdp,apps,sunshine}.yaml`.
- **Anduril LXC input — resolved (the spike "blocker" was a mis-measurement)** — KWin in the VT-less LXC handles injected mouse + keyboard fine (the "libinput enumerates zero devices" was just the missing binary); the lone real bug is the SC2 "Puck" trackpad/dialog, an upstream Valve issue. [[project-anduril-sc2-puck-linux-bugs]]
- **Harbor as upstream-registry proxy/cache for k3s** — `terraform/harbor/` creates a proxy-cache project per upstream (dockerhub/ghcr/quay/registry-k8s); `setup-k3s-registries.yaml` templates `registries.yaml` so containerd pulls through Harbor (tirion CA explicit). Rollout staged.
- **earendil foundation refresh (anduril replatform Phase 0)** — PVE 9.1.14→9.2.3, kernel pin retired (floating on 7.0), and `setup-amdgpu-host.yaml` replaces `setup-vfio-passthrough.yaml` so the AMD card binds `amdgpu` + exposes `/dev/dri`+`/dev/kfd`. PBS-backed, one reboot.
- **earendil GPU swap recovery + NIC pinned to `lan0`** — the GTX 970→9070 XT swap renumbered PCI and renamed the uplink, stranding the host; repointed live, then pinned the NIC by MAC to `lan0` (`setup-earendil-network.yaml`) so re-enumeration can't strand it again.
- **HTTP→HTTPS redirect at the Gateway** — `traefik/https-redirect.yaml`: one cluster-wide HTTPRoute on the `web` listener with a 301 `RequestRedirect`, no per-service duplication; ACME HTTP-01 still wins via the PathPrefix tiebreak.
- **Tailscale remote access — native subnet router + WoL on samwise** — `install-tailscale.yaml` advertises `192.168.1.0/24` from an always-on `tailscaled` node; `install-wakeonlan.yaml` adds a `wake-earendil` wrapper to cold-start the nightly-off hypervisor. Native systemd, not a HelmRelease.
- **Immich + Grafana + Harbor SSO via Keycloak** — three OIDC clients in `terraform/keycloak/keycloak.tf`; per-pod CA trust takes three shapes (Node `NODE_EXTRA_CA_CERTS` / Grafana OAuth-scoped `tls_client_ca` / Harbor chart `caBundleSecretName`), local admin = break-glass. [[project_in_cluster_internal_ca_trust]] [[project_sso_identity_model]]
- **Keycloak as the IdP (replacing Authentik)** — `keycloak.vingilot.internal` via the Keycloak Operator (vendored 26.6.2), external CNPG Postgres, embedded Infinispan, behind the vingilot Gateway. Switched before wiring apps, so free.
- **Harbor container + Helm registry** — `harbor.vingilot.internal`, chart 1.19 (Harbor 2.15) via Flux: CNPG Postgres + per-app Valkey + Trivy, blobs on `nfs-scratch`, admin password SOPS'd.
- **CNPG metrics → Grafana via hand-managed PodMonitors** — the operator's PodMonitor only covers the controller, so each cluster (immich/harbor/auto-water) gets a hand-managed one; the selector must include `cnpg.io/podRole: instance` or labels are silently lost.
- **Immich ML enabled + server OOM fix** — enabled `machine-learning` (CPU image, model cache on `nfs-scratch`); bumped the server limit 3Gi→6Gi to stop an OOM crashloop.
- **auto-water sensor monitoring — live on samwise** — BH1750 + HDC3022 + DS18B20 → a Python poller (30s loop, not a CronJob) → CNPG Postgres → a Flux-loaded Grafana dashboard; manifests in `swerdick/auto-water` `deploy/`. Sensing only.
- **XMP on earendil RAM — evaluated and declined** — a rated profile risks instability on the mixed kit, and earendil is the always-on hypervisor (fleet blast radius); left at JEDEC 2133, revisit only if matched.
- **anduril frame-pacing diagnosis + `mangohud` cap** — Elden Ring FPS dives traced off the infra (`steal=0`) to a forced-V-Sync staircase on the GTX 970; `setup-gaming-tools.yaml` installs `mangohud`, an `fps_limit=30` cap breaks it.
- **Anduril qemu-guest-agent (guest half)** — `setup-qemu-guest-agent.yaml` installs the in-guest daemon (in `site-anduril.yaml`), pairing with `anduril.tf`'s `agent { enabled = true }`; fixes the `tofu plan` agent-timeout + enables graceful shutdown + fsfreeze vzdump.
- **earendil Wake-on-LAN via add-in NIC** — onboard Killer E2400 has flaky WoL, so a TP-Link TG-3468 (`r8169`) was added and `vmbr0` repointed to it; `setup-earendil-network.yaml` re-arms magic-packet WoL via a MAC-matched udev rule. Power-cycle verified.
- **earendil RAM upgrade 16 → 48 GiB** — 46.9 GiB usable; the two `balloon: 0` passthrough VMs (gondor + anduril) + eregion now coexist without stopping guests to boot anduril.
- **Anduril replatformed to Kubuntu 26.04 LTS** — retired Bazzite (dropped Sunshine); `setup-sunshine.yaml` did GTX 970 NVENC via the 580.95.05 `.run` on a mainline 6.12.90 kernel; never hot-modeset a live session (wedges the card, host-reboot-only recovery).
- **GPU passthrough host-side prereqs codified** — `setup-vfio-passthrough.yaml` lifts the IOMMU cmdline, vfio modules, NVIDIA blacklist, and `vfio-pci` ID binding out of operator notes; introduced `site-earendil.yaml`. (Superseded by `setup-amdgpu-host.yaml` — Phase 0.)
- **PaperMC server on `eregion` (CT 142)** — unprivileged Debian 13 LXC via `terraform/eregion.tf`, Paper under a hardened `paper-server.service` (Aikar flags + clean `mcrcon stop`), pinned via `host_vars/eregion/`; LAN-only `:25565`, `runbooks/paper-upgrade.md`.
- **Suppress Proxmox no-subscription nag** — `setup-proxmox-no-nag.yaml` patches the `proxmox-widget-toolkit` JS on earendil + erebor; a `DPkg::Post-Invoke` apt hook re-applies it so a toolkit upgrade can't restore the popup.
- **`install-k3s.sh` refactored to ansible** — `install-k3s-server.yaml` is the source of truth for gondor's k3s server (pinned via `host_vars/gondor.yaml`), with layered idempotency + loud version-mismatch fail; workers lockstepped by `install-k3s-agent.yaml`.
- **Longer-lived ACME certs + on-boot renewal** — `install-step-ca.yaml` bumps tirion's `acme` provisioner to 90d; `setup-acme-renewal.yaml` adds `OnBootSec=2min` to earendil's + erebor's update timers so a host back from days-off renews promptly.
- **samwise joined gondor's k3s cluster as ARM worker** — `install-k3s-agent.yaml` fetches the token, adds `cgroup_memory=1 cgroup_enable=memory` to the Pi cmdline, installs k3s-agent pinned to gondor's version; carries a `role=pi:NoSchedule` taint.
- **Anduril Steam Machine hardening (Bazzite)** — `setup-bazzite-base.yaml` + `setup-sunshine.yaml` locked anduril into deliberate-upgrade mode (ostree pin, auto-update off, KDE blanking off, polkit rules). Superseded May 2026 by the Kubuntu replatform.
- **Proxmox kernel pin** — `pin-proxmox-kernel.yaml` locks earendil's kernel via `/etc/kernel/proxmox-boot-pin`; added after `7.0.0-3-pve` broke GTX 970 passthrough (later retired — see Phase 0).
- **Samwise (Raspberry Pi 5) onboarded** — added to the inventory groups; RPi OS Lite Trixie (aarch64) on WiFi + SD, full baseline applied with no per-host playbook; metrics + logs flow even while gondor is down.
- **Mirror metrics + logs to Grafana Cloud free tier** — host-alloy + k-p-s Prom dual-export with curated allowlists (~3,100 of 10k series); same dashboards import into both Grafanas via `$datasource`.
- **Hardware status dashboard (SMART + hwmon)** — `smartctl_exporter` on earendil, `homelab-hardware` Grafana dashboard for disk health + CPU/PCH temps.
- **Per-deployment workload dashboard** — `homelab-workload`, namespace + deployment-scoped utilization vs requests/limits + pod state + scoped Loki logs.
- **Flux observability dashboard in Grafana** — `homelab-flux`, gotk_resource_info-driven per-resource state plus reconcile rate/latency/errors.
- **Loki + journald shipping** — Phase 2 of observability stack; Alloy → in-cluster Loki via `loki.source.journal`, basic-auth at the Traefik edge.
- **Manage Samba config in ansible** — `manage-samba-config.yaml` templates `/etc/samba/smb.conf` from `host_vars/smb.yaml`; `testparm` validation before reload.
- **Manage NFS exports in ansible** — `manage-nfs-exports.yaml` templates `/etc/exports` from `host_vars/nfs.yaml`; idempotent re-runs.
- **CloudNativePG operator** — Postgres platform on gondor; underpins Immich, available for future stateful apps.
- **Immich** — initial deploy (ML + OOM fix landed later — see above).
- **Jellyfin** — deployed. (open: Keycloak SSO needs the 9p4 SSO plugin + tirion-CA in the .NET trust bundle + a TF client/group mapper mirroring immich/grafana/harbor.)
- **Pseudo users + sudo on root-only hosts** — `setup-pseudo-user.yaml`; SSH switched from root → pseudo with NOPASSWD sudo.
- **`nfs-common` install — generalize beyond k3s** — folded into the planned onboarding-playbook entry.
- **`tirion-root-ca` Secret cleanup** — one-off cleanup, completed.
