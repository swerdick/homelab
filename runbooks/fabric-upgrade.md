# Fabric Minecraft Upgrade Runbook (eregion)

How to bump the Minecraft/Fabric version or the mods on eregion without corrupting a world. Succeeds the Paper runbook after the Fabric rebuild. Most of the mechanics live as comments in `ansible/host_vars/eregion/main.yaml`; this covers the one genuinely non-obvious part — **modded upgrades gate on every mod having a build for the target MC version**.

> **Run `ansible-playbook` from `ansible/`** (not the repo root) so `ansible.cfg` loads the `community.sops.sops` vars plugin — otherwise the encrypted RCON password lands verbatim in `server.properties`. All commands assume `cd ansible/` first.

## Where state lives

- **World data**: `/opt/minecraft/<instance>/world/` (+ `world_nether`, `world_the_end`) per instance, on the local-zfs rootfs. In the nightly `nightly_guests` vzdump job (CT 142).
- **Mods / datapacks**: `/opt/minecraft/<instance>/mods/`, `.../world/datapacks/` — pulled from Harbor by the playbook; source of truth is `host_vars/eregion/main.yaml` + `scripts/mc-artifacts.txt`.
- **Fabric launcher**: `/opt/minecraft/fabric-server-launch.jar` → the pinned `fabric-server-mc<ver>-loader<ver>.jar`.
- **Versions**: `ansible/host_vars/eregion/main.yaml` (`minecraft_mc_version`, `minecraft_fabric_loader/installer`, per-mod `artifact`/`sha512`).
- **RCON password**: `ansible/host_vars/eregion/secrets.sops.yaml` (still keyed `paper_rcon_password`, aliased to `minecraft_rcon_password` in `main.yaml`).

## Bumping one or more mods (same MC version)

Routine — a mod publishes a new build for the current MC version.

1. Get the new version's file URL + sha512 from Modrinth (the file's `hashes.sha512`):
   ```sh
   curl -s "https://api.modrinth.com/v2/project/<slug>/version" \
     | jq -r '.[] | select(.game_versions[]=="'"$(grep '^minecraft_mc_version' host_vars/eregion/main.yaml | awk '{print $2}' | tr -d '\"')"'") | "\(.version_number)\t\(.files[0].url)\t\(.files[0].hashes.sha512)"' | head
   ```
2. Update that mod's line in **both** `scripts/mc-artifacts.txt` (tag + url + sha512) and `host_vars/eregion/main.yaml` (`artifact` tag + `sha512` + `upstream_url`). Keep them in sync. Commit.
3. **Publish to Harbor**: `./scripts/publish-mc-mods.sh` (from repo root, on the Mac). Confirm the new tag appears and Trivy scans clean-ish.
4. Preview + apply:
   ```sh
   cd ansible/
   ansible-playbook playbooks/install-fabric-mc.yaml --check --diff   # expect: oras pull of the bumped mod, restart
   ansible-playbook playbooks/install-fabric-mc.yaml
   ```
   The handler restarts only enabled instances via `mcrcon stop` (clean save).
5. Smoke test: connect to `eregion.vingilot.internal:25565`, `/spark health`, look around.

Rollback: pin the mod's version/tag/sha512 back, re-publish (old tag may still be in Harbor), re-run.

## Major MC version bump (e.g. 26.2 → 26.3)

World format may change; **one-way without a backup restore.** The gating step is mod availability.

1. **Confirm the new Minecraft version** and the matching **Fabric loader + installer** at https://meta.fabricmc.net/v2/versions/loader/<new-ver> and the Fabric blog.
2. **Check EVERY mod for a build on the new MC version** before touching anything — worldgen (Tectonic, Terralith), Distant Horizons, and the perf set (Lithium, C2ME, Chunky, FerriteCore, spark) each update independently and **lag Mojang by days to weeks**. If a mod you rely on has no build yet, *do not proceed* — wait, or drop that mod deliberately. C2ME in particular has historically been last and ships pre-release builds first.
3. **Mandatory backup** before the bump: PVE UI → Datacenter → Backup → run the nightly job now (or `vzdump 142`), wait for completion. (PBS is the deeper net if configured.)
4. Java: Fabric for a new MC line may raise the JRE floor. If it exceeds `openjdk-25` (what the playbook installs), bump the apt package + the "remove old Java" task first.
5. Update `minecraft_mc_version`, `minecraft_fabric_loader/installer`, `minecraft_launch_jar` (new tag; **blank its sha512** so the publish script prints the fresh one to paste back), and every mod's version/tag/sha512/url — in `mc-artifacts.txt` and `main.yaml`. Commit.
6. `./scripts/publish-mc-mods.sh` — note the launcher jar's printed sha512, paste into `minecraft_launch_jar.sha512`, commit.
7. `--check --diff`, then apply. **Watch first boot**:
   ```sh
   ssh eregion -- 'sudo journalctl -u fabric-server@main -f'
   ```
   Look for Fabric loading every mod without a mixin/dependency error, the world upgrader completing, and no chunk-format errors. A `Mixin apply failed` or a "requires <mod> version X" line means an incompatible mod — stop and fix before players connect.

### If the world breaks

Restore-not-debug (per `project_anduril_recovery_pattern.md`): `systemctl stop fabric-server@main`, restore the pre-bump vzdump of CT 142 from the PVE UI (rolls back the whole LXC incl. worlds), pin versions back in host_vars, `qm start 142`. Don't surgically fix a half-migrated world.

## Adding a world (new instance)

Copy the `vanilla` block in `minecraft_instances` (unique `name`/`port`/`rcon_port`), set its mods (concatenate `_mods_core` with any worldgen mods; add datapacks like `_datapack_terralith` for Terralith worlds), `enabled: true` when you want it running, re-run the playbook. The playbook scaffolds the dir, pulls mods/datapacks, writes `instance.env` + `server.properties`, and enables `fabric-server@<name>`. Worlds run one at a time by default — start/stop instances as needed; each has its own port.

## Deliberately not here

- **Staging world / non-stable channels**: for a LAN server the vzdump restore is a cheaper safety net than a parallel staging world.
- **Client mods/shaders**: client-only, see `runbooks/eregion-client.md`.
