# PaperMC Upgrade Runbook (eregion)

When and how to upgrade the PaperMC server on eregion without corrupting the world or losing player data.

PaperMC versions on the **v3 / Paper-native track** (e.g. `26.1.x`) ship frequent builds and occasionally cross MC-protocol boundaries. The two cases below cover both.

> **Run ansible-playbook from `ansible/` (not the repo root).** `ansible.cfg` only loads from the working directory; running from elsewhere silently bypasses the `community.sops.sops` vars plugin, which would write encrypted SOPS blobs into Paper's `server.properties` (and break RCON). All commands below assume `cd ansible/` first.

## Where state lives

- **World data**: `/opt/minecraft/world/`, `/opt/minecraft/world_nether/`, `/opt/minecraft/world_the_end/` on eregion (local-zfs rootfs). Backed up via PBS `guests-to-pbs` job.
- **Active JAR**: `/opt/minecraft/paper.jar` is a symlink. The real file is `/opt/minecraft/paper-<version>-<build>.jar`. Old JARs stay on disk after upgrades; clean them up manually if `/opt/minecraft` ever needs reclaiming.
- **Version pinning**: `ansible/host_vars/eregion/main.yaml` — `paper_version` + `paper_build`.
- **RCON password**: `ansible/host_vars/eregion/secrets.sops.yaml` — SOPS-encrypted. Edit with `sops <path>`.

## Case A: Minor build bump (same Paper version line)

Example: `26.1.2` build 64 → build 75. Same version line, security/perf patches only. Safe and routine.

1. Check the latest build for the current version line:
   ```sh
   curl -s "https://fill.papermc.io/v3/projects/paper/versions/$(grep '^paper_version:' ansible/host_vars/eregion/main.yaml | awk '{print $2}' | tr -d '"')" \
     | jq '.builds[-5:]'
   ```
   Confirm the channel is `STABLE`:
   ```sh
   curl -s "https://fill.papermc.io/v3/projects/paper/versions/<ver>/builds/<build>" | jq '.channel'
   ```
2. Bump `paper_build` in `ansible/host_vars/eregion/main.yaml`. Commit.
3. (Optional, but cheap) Trigger an out-of-band PBS backup of eregion: PVE UI → Datacenter → Backup → `guests-to-pbs` job → Run now.
4. Preview:
   ```sh
   cd ansible/
   ansible-playbook playbooks/install-paper-mc.yaml --check --diff
   ```
   Should show: the new JAR fetched (SHA256-verified against the v3 API response), the symlink repointed. No other tasks change.
5. Real run:
   ```sh
   ansible-playbook playbooks/install-paper-mc.yaml
   ```
   The handler runs `systemctl restart paper-server`. `ExecStop` calls `mcrcon stop` first → clean save → minimal corruption risk.
6. Smoke test: connect from the Minecraft client to `eregion.vingilot.internal:25565`, look around spawn for 30 seconds, run a couple of commands.

If something goes wrong: pin `paper_build` back to the previous value, re-run, restart. The old JAR is still on disk so the rollback doesn't need to re-download.

## Case B: Major version-line bump (world format / Java may change)

Examples: `26.1.x` → `26.2.x`, or jumping across Paper's MC-protocol boundary (e.g. when 1.22 lands). World migrations are one-way without a backup restore.

1. **Read Paper's release notes**: https://papermc.io/downloads/paper and https://github.com/PaperMC/Paper/releases — look specifically for:
   - World format / chunk format changes
   - Java version requirements (Paper 26.1.x requires Java 25; future lines may bump again)
   - Removed or renamed blocks/items
   - Command syntax changes
2. **Cross-check Minecraft client compatibility**. Paper's v3 version IDs (e.g. `26.1.2`) don't trivially map to the Mojang Minecraft client versions. Connect from a current client first or check Paper's changelog for the MC protocol version range the release supports.
3. **Check plugin compatibility** for anything in `/opt/minecraft/plugins/`. *Do not proceed* if a plugin you rely on hasn't been updated for the target Paper version yet.
4. **Mandatory PBS backup** before the bump. World format migrations are not reversible without restoring this snapshot. PVE UI → Datacenter → Backup → `guests-to-pbs` → Run now → wait for it to complete.
5. **Bump Java in the playbook if required.** Paper publishes `java.version.minimum` per release at `fill.papermc.io/v3/projects/paper/versions/<ver>`. If it's higher than what `install-paper-mc.yaml` installs (currently `openjdk-25-jre-headless`), update the apt package list + the "Remove old Java" cleanup task before bumping `paper_version`.
6. Bump *both* `paper_version` and `paper_build` in `ansible/host_vars/eregion/main.yaml`. Commit.
7. Preview with `--check --diff` from `cd ansible/`. The diff should show JAR download + symlink + restart (+ Java package change, if applicable).
8. Real run.
9. **Watch the first boot closely**:
   ```sh
   ssh eregion -- 'sudo journalctl -u paper-server -f'
   ```
   Paper runs the world upgrader lazily as players load chunks. Look for:
   - `Done (Xs)! For help, type "help"` — normal startup, world OK.
   - `WARN` / `ERROR` lines about chunk format, unknown blocks, or migration failures — investigate before letting players on.
   - Long pauses (> 60s) at "Preparing spawn area" — Paper may be eagerly converting spawn chunks; usually fine, just slow on first boot.
10. Smoke test from the client: connect, walk into chunks you haven't visited recently to trigger lazy migration, verify they load cleanly.

### If the world breaks

Restore-not-debug, per `project_anduril_recovery_pattern.md`'s principle:

1. `systemctl stop paper-server` on eregion (or via `mcrcon stop`).
2. From PVE UI → eregion → Backup → select the pre-bump snapshot → Restore. This rolls the entire LXC back, including the world data.
3. Pin `paper_version` and `paper_build` back to the previous values in `host_vars/eregion/main.yaml`. Commit.
4. `qm start 142` (or PVE UI → Start). The previous Paper version comes back up with the restored world.
5. File an issue against yourself: which plugin/feature blocked the bump, what to wait for before retrying.

Avoid trying to surgically fix a partially-migrated world — that path is full of subtle corruption.

## What's deliberately not in this runbook

- **"Test on a copy of the world first"**: for a LAN play server the operational cost of maintaining a parallel staging world (or running through PBS clone-to-test cycles) is higher than the cost of a rare bad bump. PBS restore is the safety net.
- **Pinning to non-STABLE channels** (e.g. `pre`, `rc`): not supported by this runbook. If you want to test an upcoming MC version, do it on a one-off LXC clone, not by pointing `host_vars/eregion.yaml` at a pre-release build.
- **Plugin install/update procedure**: out of scope until plugins actually land. When they do, add a section here covering the staging-plugins-in-the-playbook pattern.
