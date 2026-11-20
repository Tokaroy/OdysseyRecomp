# Update 0.2.8 (2026-11-20)

What went in, with the notes behind each:

- **Our own shader core** (`shader-core-0.2.8-plan-2026-11-17.md`): blending, write masks and the vertex layout as
  dynamic state (VK_EXT_extended_dynamic_state3, VK_EXT_vertex_input_dynamic_state) on NVIDIA and RADV; pipeline keys
  canonicalized (`key_canon`), lists keep whole keys. 17 kingdoms, each in its own run, old vs new: links in play 3506 ->
  2420, skipped draws 3028 -> 2470, frame rate the same; opening cutscene bit-identical (13 shots), no validation
  messages from it. The preparation's whole pipelines canonicalized and deduplicated.
- **Hitch causes in every log**: frames over 50 ms name their cause ([hitch]); the GPU's busy time in every stats line;
  a freeze watchdog ([freeze], 15 s without a frame: every thread's state).
- **The list-lock slowdown** (the player's session, 2026-11-18): after flights between kingdoms the game fell to 42-55
  fps for long stretches, GPU nearly idle. Reproduced on the same path with the player's settings: the render thread
  waited 600-860 ms of every 2 s for `g_list_lock` in `cmd_list` while the game thread moved the sorted list array
  (25-32k lists). `runtime/nvn/cmdbuf.c`: lookups in a hash table under their own lock, the arena reap under its own
  lock and outside it. Same path after: lock waits 0, 60 fps, render thread 600-830 ms per 2 s instead of 1300-1600.
- **In-betweens with a draw left out aren't shown** (exec.c `renderer_interp_replay` returns false): with the player's
  settings the game's skipped draws 1555 -> 20 in the Cascade Kingdom.
- **A complete save's scenarios** (hle/odyssey_warp.c `complete_save`, upstream's ODYSSEY_SAVE_COMPLETE): kingdoms
  without a moon rock (Mushroom, Dark Side, Darker Side) have 9 there, a scenario they don't have - the stage never
  finished loading. Only a moon rock scenario the kingdom has now, else the one after the ending.
- **Cutscene hook and atlas** (exec.c `vk_demo_start`, hle/odyssey_warp.c): `[demo]` lines; programs a cutscene drew
  before are built when it starts.
- `diag.c`: a halt in a locked heap stops the game with its lines instead of freezing it.
- **In-betweens replay the lists their frame ran** (`interp-replay-lists-2026-11-20.md`): the game records its next
  frame at the same command handles while a frame's in-betweens are made; at 240 the 2nd and 3rd in-betweens repeated
  the 1st and half-recorded lists made objects flicker (the Odyssey's balloon). Now even steps, 60 fps on the player's
  real screen.
- **Scene starts no longer stall** (`scene-start-list-table-2026-11-20.md`): the command-list table in sorted blocks;
  on the player's path hitches over 150 ms 48 (11.5 s) -> 3 (0.8 s, the game's own start). What is left is one frame in
  the black loading screen.
- **The scene heap halt after many trips in a row**: trips wait for the kingdom's resource loader before the next flight
  (19 flights in a row, no halt).
- `tools/test_watch.py`: one report of every problem a test run shows (stops, freezes, hitches by cause, fps drops,
  flicker and in-between stalls in `ODYSSEY_BURST` images).

Not tried: AMD / Intel on Windows, Linux, Steam Deck. No freeze at a scene start in today's ~60 starts (the watchdog
would say where).
