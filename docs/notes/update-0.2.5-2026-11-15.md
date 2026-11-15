# Update 0.2.5 (2026-11-15)

Everything left from players' reports on 0.2.4 (GitHub issues, RecompLauncher reports, a Reddit post on r/recomps).

## The shader precompile covers every shader archive

**Problem.** "The shader precompile doesn't load them all" (Reddit): 0.2.4 precompiled `ShaderData/alRenderMaterial.szs`
only (12,820 programs). Effects, sky, clouds, depth passes, post effects and agl's own screen passes were still
compiled the first time they were drawn.

**Evidence.** A scan of the whole RomFS for shader containers (`../scratch/scan_bnsh.py`): BNSH files in 16 more
archives (EffectData/EffectPtcl, the other ShaderData/alRender*, 8 layouts, 2 objects). Live-compiled code dumped
(`ODYSSEY_LOG_LIBS_CODE=1`) and searched for in the decoded RomFS (`../scratch/find_code.py`): the rest is in agl's
shader archives (`ShaderData/al*Shader.szs`, `alHdrCompose`, `alRenderFog`, ..., `SystemData/AglResource.szs`), a
format of their own (`.sharcb`, "BAHS" version 9).

**Fix** (`runtime/nvn/vulkan/exec.c`, `PC_FILES`, `pc_scan_sharcb`):
- Every BNSH in every archive that has one is read (+6,800 programs).
- agl's archives: the code blocks are found (256-aligned, NVN's 0x12345678 header, the stage in the SPH type), but
  which vertex shader goes with which fragment shader is in the source archive, and most variations carry only a patch
  of a control section. So the pairs come from the programs drawn before (`known_programs.txt` + this player's
  `cache/drawn_programs.bin`): every vertex x fragment pair of an archive is hashed as a draw hashes it and the drawn
  ones are compiled (235-239 programs; matching takes 0.2 s).
- Result: 19,876 programs precompiled (12,820 in 0.2.4), in 105-130 s on our PC (once).

## Pipelines from every stage

`tools/grand_tour.sh`: hidden runs through all 197 stages of StageData (six a run, each warped to and played ~22 s with
the camera turning). Every pipeline drawn lands in the test folder's `cache/pipes.bin`, shipped as
`runtime/nvn/vulkan/known_pipes.bin`, and every program in `known_programs.txt` (tools/known_programs.py). The
cutscene-only `Demo*` stages can't be warped to directly (the warp has no cutscene set up: a crash in
StageScene::tryChangeDemo) and are left out; five worlds in one run filled WorldHeapResource once (a test artefact).

## Map warps with the mouse (GitHub #16)

**Problem.** "It's not possible to warp between warp points on the map."
**Evidence.** Hidden runs on a copy of the player's save in Cascade: with a controller and with the keyboard (Backspace,
WASD, K) the warp works ("Top of the Big Stump"). With the right stick moving - what the captured mouse does - the
map zooms, the cursor misses the flag and A does nothing (`build/sheet6.png`).
**Fix** (`runtime/hle/input.c`): `MapLayout::exeWait` (runs every frame while the map is open) is hooked; while the map
is open the mouse moves the map's cursor (left stick) instead of zooming, and its left button is A (warp).
**Not verified:** a real mouse (the test scripts can't capture one).

## Driver crashes while building pipelines (GitHub #14, ROG Ally)

**Evidence.** The player's log: the preparation's process ended after 26 of 12,821 programs (exit 255), then access
violations inside amdvlk64.dll from a compile worker during the Bowser's ship cutscene.
**Fix** (`runtime/dispatch.c`, `device.c`): a crash whose PC is in the Vulkan driver is noted in `cache/driver.crash`
with the driver's vendor and version; from the next start that driver gets whole pipelines (no libraries, no
binaries), the path every other game uses. A driver update clears it.
**Not verified:** no such GPU here.

## Updates inside the launcher, Windows and Linux

`runtime/update.c`: the new release is downloaded as soon as the launcher sees it (no click), and "Update ... ready -
restart now" installs it. Linux (new): the `-linux-x86_64.tar.gz`, unpacked with tar, copied over the folder
`OdysseyRecomp.sh` is in by `update/apply.sh` (its own session: it outlives the program), then the new version starts.
Tested: auto-download and unpack on Windows (`ODYSSEY_UPDATE_TAG/URL`, launcher screenshot "Unpacking update").

## Linux

- Audio: SDL picks PulseAudio, then PipeWire, then ALSA (GitHub #15: crackling went away with `SDL_AUDIODRIVER=pulseaudio`).
- RecompLauncher on Linux: `recomplauncher.json` starts `OdysseyRecomp.sh` too and ships in the tar.gz; next to it the
  data (saves, settings, game files) is kept in the program's folder like on Windows (`runtime/paths.c`), unless 0.2.4's
  files are in `~/.local/share/odyssey-recomp` already.

## Other fixes

- #17 "Zig AccessDenied": a compile that fails with Access is denied (antivirus holding a file) is retried up to 6
  times with fewer jobs (`runtime/gamebuild.c`).
- #18 Easy Setup on our own copy of the game files: rebuilds the game code instead of "not found" (`runtime/ui/setup.mm`).
- Remembered pipelines' depth format follows the GPU (D24S8 where it has it, else D32S8): the shipped list works on AMD.
