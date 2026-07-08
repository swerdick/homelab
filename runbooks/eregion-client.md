# eregion Minecraft Client Setup (Prism on anduril)

Client-side setup for connecting to the eregion Fabric server (MC **26.2**) with the "vanilla-plus" far-render experience, driven by a Steam controller from the couch. **These mods are client-only — never on the server** (the server runs Fabric API + Tectonic + Terralith + Distant Horizons + perf set; see `host_vars/eregion/main.yaml`).

This is a **manual** procedure — anduril is a hand-managed gaming box (see `project_anduril_*` notes; don't automate against it), and it's an LXC, which drives the install choice below. Everything here was validated 2026-07-07.

---

## 1. Install Prism — NATIVE, not Flatpak

**Do not use the Flatpak.** anduril is a privileged Proxmox **LXC**, and Flatpak's `bwrap` sandbox fails there — `/proc/sys/user/max_user_namespaces` is read-only in the container, so `bwrap` aborts (Steam's pressure-vessel tolerates this; flatpak's bwrap doesn't). The flatpak Prism installs fine but **crashes instantly on launch** (from Steam, xrdp, or CLI — all the same bwrap failure). Use the **native portable build** instead — it launches java directly with no sandbox.

> **Automated:** the launcher binary + `.desktop` install is codified in
> `ansible/playbooks/install-anduril-prism.yaml` (in `site-anduril.yaml`) — a
> rebuild reproduces it. The manual steps below are the equivalent / for
> reference; everything *after* the install (instance, mods, account, Steam
> shortcut) stays manual.

Over SSH (or a terminal):
```bash
cd ~ && curl -fsSL -o /tmp/prism.tar.gz \
  https://github.com/PrismLauncher/PrismLauncher/releases/download/11.0.2/PrismLauncher-Linux-Qt6-Portable-11.0.2.tar.gz
mkdir -p ~/prism && tar xzf /tmp/prism.tar.gz -C ~/prism && rm /tmp/prism.tar.gz
```
Launch the GUI from the **TV/gamescope session** (needs the GPU display — an xrdp session software-renders and is the wrong place):
```bash
~/prism/PrismLauncher
```
On first run, let Prism **auto-download Java** (21+). Qt6 is already on the system.

## 2. Add it to Steam Big Picture

The "Add a Non-Steam Game → **Browse**" file picker **does nothing in the gamescope session** (known limitation). Work around it by giving Prism a `.desktop` entry so it shows up in the **checklist** directly:
```bash
mkdir -p ~/.local/share/applications
cat > ~/.local/share/applications/prismlauncher-native.desktop <<'EOF'
[Desktop Entry]
Type=Application
Name=Prism Launcher (native)
Exec=/home/pseudo/prism/PrismLauncher
Path=/home/pseudo/prism
Icon=/home/pseudo/prism/share/icons/hicolor/256x256/apps/org.prismlauncher.PrismLauncher.png
Categories=Game;
Terminal=false
EOF
```
Steam → **Add a Non-Steam Game** → tick **Prism Launcher (native)**. Do **not** force a Steam Play / Linux Runtime compat tool on it (it's a native app; forcing the runtime is what broke the flatpak).

## 3. Create the instance

**Add Instance** → Minecraft **26.2** → loader **Fabric 0.19.3** (match `minecraft_mc_version` / `minecraft_fabric_loader` in host_vars exactly). Name it `eregion` (the instance id matters for §6).

## 4. Client mods (Prism → Edit → Mods → Download; built-in Modrinth browser)

| Mod | Purpose |
|---|---|
| **Sodium** | Renderer (required by Iris). **See the version trap below.** |
| **Iris Shaders** | Shader loader. |
| **Distant Horizons** `3.1.2-b-26.2` | Client LOD renderer; receives the LODs the server distributes. Same jar as the server. |
| **Controlify** | Native controller support (see §6). |
| **Mod Menu** | In-game mod config UI. |
| **Reese's Sodium Options**, **Sodium Extra** | Optional video-settings QoL (also Sodium-version-bound). |
| *auto-pulled:* **Fabric API, YACL, Cloth Config** | Deps. |
| Optional | **Lithium**, **FerriteCore** (client perf/memory). |

> ⚠️ **Iris ↔ Sodium version trap (this WILL bite you).** Iris pins one exact Sodium build. As of 2026-07: **Iris `1.11.1` requires Sodium `0.9.0` (the non-beta, mc26.2-0.9.0)** — *not* the newer `0.9.1-beta.x`. Installing "latest Sodium" gives a beta that Iris rejects with an "Incompatible mods found!" screen. Downgrade **Sodium to 0.9.0** (Mods → select Sodium → Change Version). The Sodium-family add-ons follow suit — **Reese's Sodium Options had to go to `2.1`** to match. Rule: **keep the whole Sodium family matched to whatever Sodium version Iris pins**; when updating, update Iris + Sodium together, and if Iris complains, set Sodium to the version it asks for. (Sodium Extra is optional — remove it if it fights the pin.)

> Keep the render backend on **OpenGL** (Options → Video). 26.2 has an experimental Vulkan backend; Iris/Sodium/DH are only stable on OpenGL.

## 5. Shaders — Prism → Edit → Shader Packs → Download

- **Complementary Reimagined** — top pick: best DH support (LOD blending), truest vanilla-plus. Select it in **Options → Video Settings → Shader Packs**.
- **BSL**, **Photon** — alternatives. (Skip Complementary *Unbound* / Rethinking Voxels — too stylized.)

DH-compat shader list: https://gist.github.com/Steveplays28/52db568f297ded527da56dbe6deeec0e

## 6. Console-feel controls (Controlify + direct launch)

Two pieces, because Prism (a desktop Qt app) has no controller support but Minecraft can:

- **In-game:** **Controlify** `3.0.2` gives native controller menus/gameplay. It reads a *real gamepad*, so set the **Steam Input config for this game to a Gamepad template** (emulated Xbox), **not** keyboard/mouse — otherwise Controlify sees KB/M and won't engage.
- **Skip Prism's UI entirely:** point the Steam shortcut straight at the instance so pressing Play boots into the game:
  - **Target:** `/home/pseudo/prism/PrismLauncher`
  - **Launch Options:** `--launch eregion` (instance id)
  - **Start In:** `/home/pseudo/prism`
- Keep a **second Steam Input layout that's desktop/mouse** for the rare time you need Prism itself (adding/updating mods).

Daily flow becomes: **Big Picture → Play → in-game with Controlify.** You never navigate Prism with the stick.

## 7. Connect

**Multiplayer → Add Server** → address exactly:
```
eregion.vingilot.internal
```
(or `192.168.1.42` — no port needed; 25565 is default).

> ⚠️ **On-screen-keyboard gotcha:** the Steam virtual keyboard likes to prepend a **leading space** to the address (`" eregion.vingilot.internal"`), which Minecraft does **not** trim → "**Unknown host**". If a clean-looking address won't connect, cursor to the very start and backspace once. (Diagnosed by reading `servers.dat` — the space is invisible in the field.) Use `:` not `.` before any port.

## 8. Performance tuning (do these — they matter a lot)

The bottleneck on this stack is **CPU (Distant Horizons' render thread), not the GPU** — the 9070 XT sits at ~15–25% busy. Symptoms of getting it wrong: low FPS **and** choppy audio (the client hitches and the audio buffer underruns — same root cause).

1. **VSync OFF** (Options → Video). *Biggest single fix.* anduril's MangoHud is the intended frame limiter (`fps_limit=60,30,0`, toggle `Shift+F1`) — VSync-on fights it and forces a 60→30→20 staircase that stalls the DH thread. Turning VSync off let the DH thread stop pegging a core and the GPU pick up.
2. **Client heap → 6 GB** (Edit → Settings → Java → *Override global memory* → Max `6144`). Prism's 4 GB default causes G1 GC to run hot (~60%) with DH+shaders, giving micro-stutters. 6 GB is the sweet spot on a 12 GB box (leaves room for Steam/gamescope/Sunshine; 8 GB gets tight). Requires a relaunch.
3. **DH LOD render distance** (`lodChunkRenderDistanceRadius`) defaults very high (256 = 4096 blocks). It's tolerable at rest with VSync off + 6 GB heap, but **spikes hardest while exploring** (building new LODs). If fast-travel stutter bugs you, drop it to **~128**. GPU has headroom, so *raise* shader quality before lowering it for FPS.

## 9. Keeping it updated

- **Prism app:** self-updates (portable build ships `prismlauncher_updater`); it prompts in the GUI. No flatpak.
- **Mods/shaders:** Prism → Edit → **Mods → Check for Updates** (and Shader Packs tab). **Update Iris + Sodium together** and re-match the Sodium family (see §4 trap).
- **MC version lockstep:** stay on 26.2 to match the server; only jump MC versions **after** the server moves (`runbooks/fabric-upgrade.md` bumps `host_vars/eregion/main.yaml`), then match the client. A client/server MC or DH mismatch refuses the connection or disables DH LOD sharing.
- If DH LODs look sparse, an op can widen them server-side: `/chunky radius <n>; /chunky start`.
