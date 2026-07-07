# eregion Minecraft Client Setup (Prism on anduril)

Client-side setup for connecting to the eregion Fabric server with the "vanilla-plus" far-render experience. **These mods are client-only — they are never installed on the server** (the server runs Fabric API + Tectonic + Terralith + Distant Horizons + the perf set; see `host_vars/eregion/main.yaml`). This is a manual Prism Launcher procedure, not automated: anduril is a hand-managed gaming box (see `project_anduril_*` notes — don't automate against it), and Prism is a GUI workflow.

anduril's AMD 9070XT handles Distant Horizons + shaders at high render distance comfortably.

## Instance

Prism Launcher → **Add Instance** → Minecraft **26.2** → loader **Fabric 0.19.3**. Match the server (`minecraft_mc_version` / `minecraft_fabric_loader` in host_vars) exactly.

## Client mods (drop in the instance's `mods/`, or use Prism's mod browser)

Version-match all to MC 26.2 / Fabric.

| Mod | Purpose |
|---|---|
| **Fabric API** | Base library (same one the server uses). |
| **Sodium** | Rendering-performance rewrite — required for Iris. |
| **Iris** | Shader loader (loads the shaderpacks below). |
| **Distant Horizons** `3.1.2-b-26.2` | Client LOD renderer. On this server it receives LOD data the server distributes, so distant terrain fills in without you walking it. Same jar as the server's. |
| **Mod Menu** | In-game mod config UI. |
| **YACL** + **Cloth Config** | Config-screen deps for DH/Iris/others. |
| Optional: **Lithium**, **FerriteCore** | Client-side perf/memory, harmless. |

> Keep the client on the default **OpenGL** backend. MC 26.2 ships an experimental Vulkan renderer; Iris/Sodium/DH are stable on OpenGL, not yet on Vulkan.

## Shaders (vanilla-plus + Distant-Horizons-compatible)

Download the shaderpack `.zip` into the instance's `shaderpacks/`, then select it via **Options → Video Settings → Shader Packs** (Iris). DH imposes shader constraints — these are chosen for explicit DH support. Authoritative DH-compat list: https://gist.github.com/Steveplays28/52db568f297ded527da56dbe6deeec0e

- **Complementary Reimagined** — top pick. Best DH support (LOD blending + config toggles), truest vanilla-plus look.
- **BSL** (`v8.2.0+`) — classic vanilla-plus, DH support.
- **Photon** (sixthsurge) — semi-realistic, DH support.

Skip for this aesthetic: **Complementary Unbound** and **Rethinking Voxels** (more stylized than "vanilla plus").

## Connect

Multiplayer → Add Server → `eregion.vingilot.internal:25565` (or `192.168.1.42:25565`). Enable Distant Horizons in its config (distant generation is served by the server). Turn on the shader in Iris; confirm shader + DH render together.

## Notes

- If DH LODs look empty at first, the server may still be pre-generating — an op can run `/chunky radius <n>; /chunky start` on the server so the LODs the server distributes cover a wider area.
- A version mismatch between client and server Fabric/MC or DH will refuse the connection or disable DH LOD sharing — keep them in lockstep with `host_vars/eregion/main.yaml`.
