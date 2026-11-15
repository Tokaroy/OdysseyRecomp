#!/bin/bash
# The grand tour: hidden runs through every stage of the game (StageData's *Stage names: kingdoms, sub-areas, bosses,
# cutscenes, 2D, Moon, Mushroom...), six stages a run, each warped to straight (runtime/hle/odyssey_warp.c) and played
# for ~22 s with the camera turning. Every pipeline drawn and program set up lands in the test data folder's cache
# (cache/pipes.bin, cache/drawn_programs.bin): the lists the release ships (known_pipes.bin, known_programs.txt).
#   tools/grand_tour.sh <stage list file> [first line]      (logs: build/tour/<n>.log; EXE=... picks the build)
cd "$(dirname "$0")/.."
LIST=$1
FIRST=${2:-1}
mkdir -p build/tour
IN=""
for f in $(seq 700 400 12000); do IN="$IN$f:A:4,"; done  # (through the warp's flight / dialogs; a jump in play)
for s in $(seq 0 40); do
    b=$((1500 + s * 260))
    IN="$IN$b:STICK_UP:120,$((b + 120)):RSTICK_RIGHT:70,$((b + 190)):STICK_LEFT:70,"
done
mapfile -t ST < <(tail -n +"$FIRST" "$LIST" | tr -d '\r' | grep -v '^$')
for ((i = 0; i < ${#ST[@]}; i += 6)); do
    W=""
    for ((j = 0; j < 6 && i + j < ${#ST[@]}; j++)); do W="$W${W:+;}${ST[i + j]}@$((1600 + j * 1300))"; done
    n=$((FIRST + i))
    SECS=$((40 + 6 * 24)) LOG=build/tour/$n.log ODYSSEY_NO_USER_INPUT=1 ODYSSEY_VK_PROF=1 ODYSSEY_WARP="$W" \
        ODYSSEY_INPUT="$IN" tools/hidden_run.sh > /dev/null
    echo "run $n: $(grep -c 'stage scene .* running' build/tour/$n.log) scenes, $(grep -c 'exception\|FATAL' build/tour/$n.log) crashes ($W)"
done
