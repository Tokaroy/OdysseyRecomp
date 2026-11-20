# Scene starts: the command-list table (2026-11-20)

## Problem

After a fall, a reload or entering a kingdom, the first frames of the new scene took 150-280 ms each, about 5 of them
(over a second); the player's path over three kingdoms had 48 hitches over 150 ms, 11.5 s in all.

## Evidence

- The hitch lines: "game / other" or "new textures", the render thread's own work 8-27 ms of those frames, no GPU wait.
- `ODYSSEY_SPROF` over a scene start (`../scratch/sprof_scene.txt`): the game's main thread blocked about a third of
  the time in `lists_overwritten` / `nvnCommandBufferBeginRecording` (the list table's locks), the main game thread in
  the game's own Yaz0 decompression.
- New counters (the hitch line's "list table: waits, held"): the game's threads held the table 47-61 ms of every frame
  of a reload (Cascade, 10,500 lists).

## Cause

The alive command lists were one array sorted by handle (`g_lists`). Every list begun or ended moved every list after
its place (a memmove of up to 250 KB), and a scene start begins and ends thousands a frame.

## Fix

`runtime/nvn/cmdbuf.c`: the table is sorted blocks of up to 256 lists (`lt_*`): a binary search over the blocks, then
over one block; a change moves at most one block (a full one splits in two, an empty one goes). The same operations as
before: the first list at an address or after (`lt_ge`), begin / replace (`lt_put`), end every list in a range
(`lists_overwritten`). Checked against the old sorted array with random operations (`../scratch/lt_test*.c`, up to
14,657 lists in 120 blocks). The hitch line shows the table's waits / hold time when they pass 5 ms.

## Verified

- The reload: four hitches (73, 120, 63, 57 ms) -> one (115 ms, a GPU wait); the table under 5 ms a frame.
- The player's path (in-betweens on): hitches over 150 ms 48 (11.5 s) -> 3 (0.8 s, the game's start), fps windows
  under 58: 37 -> 13 (scene starts).
- What is left at a scene start is one frame of 110-150 ms waiting for the GPU: 64 draws of a 32 x 32 noise target
  (`fs 72707fea00`, a cell loop; our translation's pc state machine makes it ~75 ms). It falls in the black loading
  screen (images at frames 2664-2684 all black), so it is not seen.

Not verified: AMD / Intel, Linux.
