# Update 0.2.6 (2026-11-16)

From 72 RecompStore reports, 22 GitHub issues and their logs (`../scratch/reports/`), with the council
(`../scratch/council_026.md`).

## Shaders: a new cache, prepared at Play behind our own loading screen

**Problem.** Players' logs: the preparation took 70 s (RTX 4070 Ti) to 323 s (RTX 3050 laptop) to 1,150 s (RX 6400)
and left 0.5-2.4 GB; ours was 3.1 GB on disk (cache/spirv: 16,421 files, 1.88 GB of real bytes, ~114 KB a module;
cache/pbin: 20,079 files, 1.28 GB).
**Cause.** Every one of the 20,069 programs of the game's archives was translated, stored as its own file and
compiled by the driver into binaries - though a run through all 197 stages draws about 3,800 of them.
**Fix.**
- `runtime/nvn/vulkan/shaders.c`: one file, `cache/shaders.pack` - SPIR-V packed with zstd, appended with one write a
  record (the preparation's processes and the game add to it together), an index in memory. The old folders are
  renamed and removed in the background on the first start (`vk_shader_cache_cleanup`).
- `exec.c` precompile: every archive is read and matched, but only the programs drawn before (the shipped list from
  the 197-stage tour + this player's) are translated and compiled; the rest when the game sets them up. Each program
  carries whether it was drawn, hashed exactly as a draw hashes it. `ODYSSEY_PRECOMPILE_ALL=1`: all, as before.
- `runtime/ui/launcher.mm` `loading_draw`: Play shows a full screen card (what it does, how many, a bar, percent,
  time left).
**Verified** (RTX 4070 Ti, cold cache, 4 kingdoms, `build/cold12.log` against `build/cold10.log`): preparation 91 s ->
20.7 s, cache 3.1 GB -> 453 MB; in play the same as 0.2.5 (46 library compiles, 20 after the first scene; 3 draws
skipped). Upgrade from a 0.2.5 cache: old folders removed, preparation 18.8 s, the game starts.

## Frame rate: 120 / 180 / 240 / Match display
The in-betweens were already real frames (each draw replayed with the game's state blended: interp.c). Now 1-3 of them
a game frame (`device.c interp_images`, t = k/n), never more than the display's refresh rate; the brake steps down
(240 -> 180 -> 120) before it pauses. Verified: >120 in-betweens/s in a hidden run (the hidden window runs at 60 Hz, so
180/240 can only be judged on a fast display). The game's logic stays at 60 (it has no variable time step).

## Controls (#19, #21)
- Motion sensitivity (Controls tab, 60% by default; 0 = off), scaled around the controller's resting gravity.
- No burst of throws when the game reads the sensors again after a pause (death screen): 200 ms at rest.
- A Joy-Con pair's second Joy-Con reads at rest: one flick is a normal throw, not a spin.
- `runtime/hle/dsu.c`: motion from a DSU (cemuhook) server - sc2dsu (Steam Controller), BetterJoy, DS4Windows - when the
  controller has no gyro of its own. Verified with a fake server (`../scratch/fake_dsu.py`).

## Steam Deck
720p internal resolution by default on the Deck (and back in the menu as "720p (handhelds)"); the shader preparation
is the Deck's other half (its 865 ms frames). Not run on a Deck.

## Not done
Native rendering above 60 without the in-between replay (the logic is fixed 60 Hz), game update 1.4.0, #20's crash
(no log), the Z1 black screen (0.2.5's driver-crash fallback), a long-session slowdown (RX 6700 XT, hours).
