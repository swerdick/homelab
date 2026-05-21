# PaperMC Upgrade Runbook (eregion)

When and how to upgrade the PaperMC server on eregion without corrupting the world or losing player data.

PaperMC ships frequent builds — sometimes weekly — for the same Minecraft version, and occasional Minecraft version bumps that may migrate the world format. The two cases need different procedures.

## Where state lives

- **World data**: `/opt/minecraft/world/`, `/opt/minecraft/world_nether/`, `/opt/minecraft/world_the_end/` on eregion (local-zfs rootfs). Backed up via PBS `guests-to-pbs` job.
- **Active JAR**: `/opt/minecraft/paper.jar` is a symlink. The real file is `/opt/minecraft/paper-<mc_version>-<build>.jar`. Old JARs stay on disk after upgrades; clean them up manually if `/opt/minecraft` ever needs reclaiming.
- **Version pinning**: `ansible/host_vars/eregion.yaml` — `paper_mc_version` + `paper_build`.

## Case A: Minor build bump (same Minecraft version)

Example: `1.21.11` build 69 → build 75. Same MC version, security/perf patches only. Safe and routine.

1. Check the latest build for the current MC version:
   ```sh
   curl -s "https://api.papermc.io/v2/projects/paper/versions/$(grep '^paper_mc_version:' ansible/host_vars/eregion.yaml | awk '{print $2}' | tr -d '"')" | jq '.builds[-5:]'
   ```
   Confirm the channel is `STABLE`:
   ```sh
   curl -s "https://api.papermc.io/v2/projects/paper/versions/<ver>/builds/<build>" | jq '.channel'
   ```
2. Bump `paper_build` in `ansible/host_vars/eregion.yaml`. Commit.
3. (Optional, but cheap) Trigger an out-of-band PBS backup of eregion: PVE UI → Datacenter → Backup → `guests-to-pbs` job → Run now.
4. Preview:
   ```sh
   ansible-playbook -i ansible/inventory.yaml ansible/playbooks/install-paper-mc.yaml --check --diff
   ```
   Should show: the new JAR fetched, the symlink repointed. No other tasks change.
5. Real run:
   ```sh
   ansible-playbook -i ansible/inventory.yaml ansible/playbooks/install-paper-mc.yaml
   ```
   The handler runs `systemctl restart paper-server`. `ExecStop` calls `mcrcon stop` first → clean save → minimal corruption risk.
6. Smoke test: connect from the Minecraft client to `eregion.vingilot.internal:25565`, look around spawn for 30 seconds, run a couple of commands.

If something goes wrong: pin `paper_build` back to the previous value, re-run, restart. The old JAR is still on disk so the rollback doesn't need to re-download.

## Case B: Major Minecraft version bump (world format may migrate)

Examples: `1.21.4` → `1.21.5` (point release that may touch world format), `1.21` → `1.22` (definitely touches world format). World migrations are one-way without a backup restore.

1. **Read the upstream changelog**: https://www.minecraft.net/en-us/article/ — look specifically for:
   - World format / chunk format changes
   - Removed or renamed blocks/items (your existing world may contain them)
   - Command syntax changes
   - Default gamerule changes
2. **Check plugin compatibility** for anything in `/opt/minecraft/plugins/`. Each plugin's release notes/page should declare which MC versions it supports. Major MC bumps frequently break plugins until the maintainer updates. *Do not proceed* if a plugin you rely on hasn't been updated for the target version yet — drop the plugin, wait for an update, or stay on the current MC version.
3. **Mandatory PBS backup** before the bump. World format migrations are not reversible without restoring this snapshot. PVE UI → Datacenter → Backup → `guests-to-pbs` → Run now → wait for it to complete.
4. Bump *both* `paper_mc_version` and `paper_build` in `ansible/host_vars/eregion.yaml`. Commit.
5. Preview with `--check --diff`. The diff should show only the JAR download + symlink + restart.
6. Real run.
7. **Watch the first boot closely**:
   ```sh
   ssh eregion -- 'sudo journalctl -u paper-server -f'
   ```
   Paper runs the world upgrader lazily as players load chunks. Look for:
   - `Done (Xs)! For help, type "help"` — normal startup, world OK.
   - `WARN` / `ERROR` lines about chunk format, unknown blocks, or migration failures — investigate before letting players on.
   - Long pauses (> 60s) at "Preparing spawn area" — Paper may be eagerly converting spawn chunks; usually fine, just slow on first boot.
8. Smoke test from the client: connect, walk into chunks you haven't visited recently to trigger lazy migration, verify they load cleanly.

### If the world breaks

Restore-not-debug, per `project_anduril_recovery_pattern.md`'s principle:

1. `systemctl stop paper-server` on eregion (or via `mcrcon stop`).
2. From PVE UI → eregion → Backup → select the pre-bump snapshot → Restore. This rolls the entire LXC back, including the world data.
3. Pin `paper_mc_version` and `paper_build` back to the previous values in `host_vars/eregion.yaml`. Commit.
4. `qm start 142` (or PVE UI → Start). The previous Paper version comes back up with the restored world.
5. File an issue against yourself: which plugin/feature blocked the bump, what to wait for before retrying.

Avoid trying to surgically fix a partially-migrated world — that path is full of subtle corruption.

## What's deliberately not in this runbook

- **"Test on a copy of the world first"**: for a LAN play server the operational cost of maintaining a parallel staging world (or running through PBS clone-to-test cycles) is higher than the cost of a rare bad bump. PBS restore is the safety net.
- **Pinning to non-STABLE channels** (e.g. `pre`, `rc`): not supported by this runbook. If you want to test an upcoming MC version, do it on a one-off LXC clone, not by pointing `host_vars/eregion.yaml` at a pre-release build.
- **Plugin install/update procedure**: out of scope until plugins actually land. When they do, add a section here covering the staging-plugins-in-the-playbook pattern.
