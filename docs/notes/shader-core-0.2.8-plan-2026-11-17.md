# Our own shader core for 0.2.8: plan (2026-11-17)

Not released. Preparation only, on the player's word ("جهزوا للشيدرز عشان التحديث الجاي بس لا تنزلون شي").

## Why

The shader/pipeline path came from Power Moon Recomp 0.2.1 (precompile before the first start) and was improved on top
of it in 0.2.4-0.2.7: pipelines ahead, a single pack, drawn programs only, a loading screen at Play. Players still report
stutter. The council (5 advisors plus peer review, 2026-11-17) agreed that the weak part isn't the translator or the
pack. It is **the pipeline key**:

- A pipeline today is keyed by the program plus the vertex layout (formats, strides, divisors per attribute), blend
  state and write mask per target, target formats, samples, alpha-to-coverage, polygon fill, depth clamp, and, for the
  fragment shader, the render target kind (`rt_kind`).
- So one program fans out into many pipelines. Each new combination is a link at its first draw: entering a place
  linked 458 pipelines in 2 s with every shader cached (a 184 ms frame). Each link past the 3 ms budget is a draw
  skipped (objects flicker).
- On the Switch all of that state is plain registers; nothing is baked into the shader.

GPUs without pipeline libraries (AMD's legacy driver: RX 580/570, Vega iGPUs) get **no** precompile at all today. Every
pipeline is built whole at its first draw (20-200 ms).

## The design

1. **Hitch causes in every log** (done 2026-11-17, `vk_prof_frame` in exec.c): each frame over 50 ms names what it
   waited on: a draw waiting for a build, a build done right in the draw, pipeline links, a held frame, the GPU,
   present, new textures, or the game. Always on for the first 300 hitches of a run, so players' logs show it too.
   Every later step is judged by these numbers.
2. **The key depends on the shader, not the state** (GPUs that can):
   - `VK_EXT_extended_dynamic_state3`: color blend enable / equation / write mask, alpha-to-coverage, rasterization
     samples, polygon mode and depth clamp become dynamic state, set per draw like depth and stencil already are.
   - `VK_EXT_vertex_input_dynamic_state`: the vertex layout too (`vkCmdSetVertexInputEXT`).
   - Each sub-feature is used only where the driver reports it (it's per feature, not per extension), and stays in the
     key where it is missing. The vertex-input and fragment-output libraries then shrink to a handful (topology class;
     target formats and samples), and a pipeline becomes about one per program and target-format set.
   - Supported: NVIDIA (all of it, checked on the RTX 4070 Ti, driver 621.14), RADV / Steam Deck. AMD Windows and Intel
     support it partially. The old path stays as the automatic fallback.
3. **`rt_kind` out of the fragment key**: the output type per target as a specialization constant, so one SPIR-V and
   one compile serve float and integer targets. The fragment shaders drawn to integer targets stop compiling in play.
4. **Whole pipelines ahead for GPUs without libraries**: at Play, the known pipeline list (`known_pipes.bin` plus the
   player's `pipes.bin`) is built as whole pipelines on workers into the pipeline cache. With the smaller key this list
   is affordable.
5. **Scenes and cutscenes known ahead (the atlas)**: the tour records the pipeline keys per stage and per scene/demo.
   When a scene starts warming up (`odyssey_scene_warming`), its whole set is linked before the fade-in ends, and the
   fade waits until it's done. Nothing is skipped or waited for in a cutscene.
6. **Versioned cache keys**: the cache and lists are keyed by the Maxwell code hash plus a translator version, not by the
   SPIR-V hash, so a translator change doesn't throw the tour away again. The key-format change in step 2 bumps the
   list version once.
7. **Re-record the tour** (`tools/grand_tour.sh`, all 197 stages) with the new keys before the release, and ship the new
   `known_pipes.bin` / `known_programs.txt`.

## How it's judged

`tools/bench_kingdoms.sh` before and after (same stages, same input), on a fresh cache and a warm one: frames over
50 ms, draws skipped, compiles and links in play, and the hitch causes. The baseline is 0.2.7 (`build/bench/base028_*`).
It isn't released unless skipped draws and hitches drop and no kingdom gets worse. An env switch
(`ODYSSEY_SHADER_CORE=old`) brings back the 0.2.7 path.

## What's in the code so far (2026-11-17, not released)

- **Hitch causes** (`vk_prof_frame`, exec.c), as above.
- **The new core, behind a switch**: `ODYSSEY_SHADER_CORE=new` turns on blending, write masks and the vertex layout
  per draw where the driver has them (device.c, `key_canon` / `set_core_state` in exec.c). On by default for NVIDIA and RADV (see
  Verification). Pipeline records stay whole keys, so `known_pipes.bin` and every player's `pipes.bin` keep
  working with both cores (`prelink_job` canonicalizes them).
- **Cutscenes**: `ProjectDemoDirector::requestStartDemo` / `endDemo` are hooked (hle/odyssey_warp.c): `[demo] start
  "<name>"` lines in the log next to the hitches. The cutscene atlas (exec.c `vk_demo_start`, `cache/demos.bin`)
  remembers the programs each cutscene drew new pipelines for, and when that cutscene starts, sends the ones not yet
  built to the urgent queues. `ODYSSEY_DEMO_ATLAS=0`: off.

## Measurements (RTX 4070 Ti, warm cache, `tools/bench_kingdoms.sh`, 120 s per kingdom)

| kingdom | 0.2.7 exe: hitches / skipped / links | this build, old core | this build, new core |
|---|---|---|---|
| Cap | 7 / 1384 / 278 | 5 / 1 / 39 | 5 / 1 / 31 |
| City | 12 / 278 / 207 | 11 / 52 / 225 | 13 / 119 / 178 |
| Sand | 5 / 188 / 102 | 6 / 34 / 95 | 6 / 20 / 73 |
| Sea | 5 / 7 / 85 | 8 / 686 / 199 | 9 / 8 / 65 |

(Skipped draws vary a lot from run to run: the game's timing differs.) With the hitch causes, every hitch in these
runs is at a scene start (the first frame after loading, and the warp's loading): the first frame's submission with
~500 new textures (100-350 ms) and the warm-up's builds right in the draw (~110-140 ms). **In play, no hitch came from
shaders on this GPU.** The new core links 20-65 % fewer pipelines. So on NVIDIA with a warm cache the shader path is
already fine. The players' reports have to come from other GPUs (no libraries, no binaries), from a first run, or from
scene starts. The next measurements are with `ODYSSEY_NO_GPL=1` (the legacy AMD driver's case).

### No libraries (`ODYSSEY_NO_GPL=1`, the legacy AMD driver's case) and a new player (empty cache)

| run | old core | new core |
|---|---|---|
| Sand, no libraries: whole pipelines built | 2727 | 1816 (-33 %) |
| City, no libraries: whole pipelines built | 2872 | 1795 (-37 %) |
| empty cache + empty save (preparation, opening cutscene, first stage): hitches | 10 | 5 |
| same: links / skipped draws | 42 / 3 | 32 / 3 |
| inside the opening cutscene: hitches | 4 | 1 |

(The skipped draws in the no-library runs went up with the new core: its whole pipelines were new to the driver's
cache in that folder, while the old ones were cached from earlier runs. A second run would show the warm numbers.)

## Verification (2026-11-17)

- **Images**: the opening cutscene from an empty save plays the same each run. 13 shots at 4K (frames 1650-3450,
  every 150) with each core are **bit-identical** (same md5; the logs confirm one run per core, 19 vs 14 links). These
  frames are full of blending: lens flares, transparency, particles. Kingdom runs (Cap, Sand) match too where the runs
  didn't drift apart (Sand: 0.03-0.37 mean difference).
- **Vulkan validation layer** (`ODYSSEY_VK_VALIDATION=1`, MSYS2's layer): with the new core no message about dynamic
  state, blending, write masks or vertex input in ~350 frames of a stage (~150,000 draws). The only message,
  `VUID-VkGraphicsPipelineCreateInfo-pLibraries-06613` (the two shader libraries' layouts), is the same with the old
  core: older, not from this change. The layer itself crashes after ~90 s in both cores (inside the layer, in
  libwinpthread): it can't cover longer runs.
- **Frame interpolation** (120 fps): in-betweens 59.5-60.5/s with each core, the same match rates (97-98 %), no
  errors. (Replays go through `draw_`, which sets the new state itself.)
- **Code review**: every pipeline bind other than the game's draws is in its own pass, and the game's pass start
  forgets the state cache, so the per-draw state is always set again. The preparation's whole pipelines
  (`prepare_whole_pipelines`) now go through `key_canon` and are deduplicated: before, they'd have been built with whole
  keys that the game never asks for under the new core.
- **Default**: on for NVIDIA (measured here) and RADV (Steam Deck, Linux AMD). Off for AMD's and Intel's Windows
  drivers and Intel on Linux until it's tried there (`ODYSSEY_SHADER_CORE=new` turns it on, `=old` off everywhere).

Not verified: AMD and Intel GPUs (no hardware here), the cutscene atlas in an in-stage cutscene (the scripted runs
don't reach one: the opening is its own scene, not `requestStartDemo`).

## Not chosen

- `VK_EXT_shader_object` as the main path: its support is uneven on the GPUs that stutter most (legacy AMD, Arc on
  Windows), and it bypasses pipeline caches and binaries.
- Vertex pulling in the translator: it works everywhere, but it changes every shader (a full re-tour) and costs GPU
  time per vertex. It's kept as an option for GPUs without vertex-input dynamic state, if the measurements call for it.
- Uploading players' lists (federated atlas): privacy, and a service to run. Maybe later, opt-in.
