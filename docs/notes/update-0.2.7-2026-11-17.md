# Update 0.2.7 (2026-11-17)

Reports since 0.2.6 (RecompStore, GitHub #23, #24, the player's own log) and the council (`../scratch/council_027_brief.md`).

## The new look: "Starry Voyage" (the player's pick of three animated previews)
`runtime/ui/launcher.mm`: a night sky (twinkling stars, a shooting star every 7 s) over a planet's glowing rim, the
game's logo floating and turning a little, the menu as stars along the rim (Settings, Controls, Play as a glowing yellow
pill, Game, Quit), the version bottom right with "up to date" once the release list was read. `runtime/ui/theme.h`:
the palette of every menu (night indigo, star yellow for the selection); the in-game menu (Esc) gets the stars and the
planet's rim behind its rows (`menu.mm menu_stars`). Previews: `build/design/launchers.html` (local, not shipped: it
holds the player's logo).

## Frame rate
- The player set 240 on a 165 Hz display and got 120: 0.2.6 capped the in-betweens to the display. Now 120/180/240
  render that many (MAILBOX: the display shows the newest at each refresh), Uncapped up to 360, Match display keeps the
  cap; without MAILBOX (FIFO only) the cap stays. Measured: each in-between costs 4-6 ms of CPU (the replay, then the
  blend), done in turn - on the RTX 4070 Ti / i7 PC at 1080p in Cascade, 240 steps down to 180 / 120 (the brake) in
  busy views. Making the replays cheaper is the next step.
- VSync setting: on = MAILBOX (no tearing), off = IMMEDIATE (tearing, least delay); applied at once (new swapchain).

## Shaders
The effects' archive (EffectPtcl, 4,453 programs) is prepared whole, drawn before or not: "freezes for a second when
smashing boxes / attacking enemies" were effects the 197-stage tour hadn't drawn. Cost: ~30 s more preparation here
(6,872 programs, 53 s on a fresh cache), once.

## Fixes
- #24 Linux "SDL_Init: No available video device": the cross-built SDL asked for "libX11.so" (only with -dev packages);
  the run-time library names are pinned to their sonames (libX11.so.6, libpulse.so.0...) in `tools/linux/cross_build.sh`.
  Not run on Linux here.
- #23 CPUs without AVX2 (Ivy Bridge): the game code is built for x86-64-v2 instead (gamebuild.c); only CPUs without
  SSE4.2 are refused.
- The update check worked in the player's log ("latest 0.2.6, this is 0.2.6"); the launcher now says "up to date".

## Not done
Game update 1.4.0: the update has to be decrypted with the player's keys and the game code regenerated with every hook
moved to the new version's addresses - its own project. Cutscene stutter and the island drop: the player's log shows
94-279 ms frames at scene changes (shader loading of the new scene), steady 60 otherwise.
