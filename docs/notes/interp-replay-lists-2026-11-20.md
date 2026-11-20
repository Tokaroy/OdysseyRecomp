# In-betweens ran the next frame's command lists (2026-11-20)

## Problem

The player saw the Odyssey's balloon flicker with frame interpolation on (240, their real screen). The test watcher
(`tools/test_watch.py` with `ODYSSEY_BURST`) showed more than a flicker: at 240 (three in-betweens a frame) the second
and third in-betweens were the first one again, pixel for pixel, in every frame of a camera turn. The screen showed
the frame, one in-between three times, then the next frame: a stutter, and wherever a list was caught half-recorded,
objects missing from an in-between (the flicker).

## Evidence

Sand Kingdom, the camera turned to the Odyssey and turning on (`../scratch/real_balloon.sh`, burst runs in
`build/bench/odyssey_*.log`):

- The balloon's position in the burst images: the frame, then in-between 1 at ~¼ of the way, then in-betweens 2 and 3
  identical to 1 (mean difference 0.000), then the next frame.
- The blended uniforms were right (`ODYSSEY_INTERP_DEBUG` + `ODYSSEY_INTERP_DEBUG_CB`: t = ¼, ½, ¾ per replay), and
  reversing the order (¾ first) made all three ¾: whatever the first replay drew stayed.
- Not the twins (`ODYSSEY_INTERP_TWINS=0`), not the uniform copy cache (`ODYSSEY_NO_CB_CACHE`), not the feedback
  snapshots, not the view cache, not a per-pass submission.
- The render targets of each replay's passes: replay 1's last pass drew into the frame's window image, replays 2 and 3
  into the other window image - the next frame's.

## Cause

A replay runs the frame's command lists by handle (`interp_handles` -> `exec_list` -> `cmd_list`). A handle is the
guest address a list was begun at, and Odyssey records its next frame into the same command memory while this frame's
in-betweens are still being made. The first replay usually ran before that; the later ones ran the next frame's list
(whole: the in-between went to the next frame's image, the first one stayed on screen; half-recorded: draws missing).
Not new in 0.2.8: the lookup was by handle before the list-table change too.

## Fix

- `interp.c`: while the game runs a logged frame, `interp_list_note` keeps each list it runs (nested calls too) with
  the records it ran, in order; `interp_list_rec` gives a replay those same records (the next in order, else any with
  that handle). A list the frame never ran is left out (the in-between isn't shown).
- `exec.c` `exec_list`: a replay takes its records from `interp_list_rec`, never from `cmd_list`.
- `cmdbuf.c`: a released command arena is freed only once four more frames have closed and no replay is pending (the
  records a replay runs live in it).
- `tools/test_watch.py`: in-betweens that repeat the image before them while the frame moves, or that aren't between
  their two frames, are reported ("in-between stall / jump").

## Verified

- Same run, same frames: the steps frame -> in-between 1 -> 2 -> 3 -> frame are even (2.8, 2.8, 2.8, 2.8 / 3.3, 3.3,
  3.3, 3.3), the balloon moves a little each image. The watcher finds no flicker and no stall; it does report a stall
  when two in-betweens are replaced with the first.
- The player's path over three kingdoms with in-betweens (`userpath_fixlists`): 60 fps as before; the dips are scene
  restarts (Mario falling), as many per restart as before the fix.
- Real screen, orbiting the Odyssey for 150 s: 60.0 throughout, no in-between left out, in-betweens ready 3 ms before
  their time.

Not verified: AMD / Intel GPUs, 120 / 180 (one or two in-betweens: the same code).
