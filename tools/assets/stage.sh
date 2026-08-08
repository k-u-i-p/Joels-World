#!/bin/bash
#
# Copies everything the apps ship — the art from `assets/` and the authored world from
# `data/` — into a bundle directory.
#
# Both Xcode targets run this from a build phase, with the destination pointed at
# `$BUILT_PRODUCTS_DIR/$UNLOCALIZED_RESOURCES_FOLDER_PATH/GameAssets`. Nothing is fetched over
# HTTP any more and the socket no longer carries the world, so anything missing here is
# missing at runtime — see PLAN.md §5.
#
# The list is explicit rather than "copy everything" because both trees are *working* trees:
# the full-size map layers the slicer reads (~90 MB) sit in the same directories as the chunks
# it writes, and the AI agents' prompt files and logs sit beside the JSON the apps need.
#
# Usage: stage.sh <destination>

set -euo pipefail

DEST="${1:?usage: stage.sh <destination>}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SRC="$ROOT/assets"
DATA="$ROOT/data"

for tree in "$SRC" "$DATA"; do
  if [ ! -d "$tree" ]; then
    echo "error: tree not found at $tree" >&2
    exit 1
  fi
done

mkdir -p "$DEST"

# Whole directories. Everything in them is reachable at runtime: every GLB is a character part
# or a map prop, every clip is an emote, an ambience or a minigame sound.
WHOLE_DIRS=(models media avatars minimaps)

# Per-map: the sliced tiles, the walkability mask, and any GLB props the map places. The
# source layers next to them are slicer input and are deliberately left behind.
MAP_DIRS=(junior_school main_building pool detention)

# One-offs.
FILES=(minigames/tennis/map.svg)

RSYNC=(rsync -a --delete --exclude '.DS_Store' --exclude '*_meta.json')

for dir in "${WHOLE_DIRS[@]}"; do
  if [ ! -d "$SRC/$dir" ]; then
    echo "error: missing asset directory $dir" >&2
    exit 1
  fi
  mkdir -p "$DEST/$dir"
  "${RSYNC[@]}" "$SRC/$dir/" "$DEST/$dir/"
done

for dir in "${MAP_DIRS[@]}"; do
  if [ ! -d "$SRC/$dir/chunks" ]; then
    echo "error: $dir has no chunks — run 'npm run build' in tools/assets first" >&2
    exit 1
  fi
  mkdir -p "$DEST/$dir"
  "${RSYNC[@]}" "$SRC/$dir/chunks/" "$DEST/$dir/chunks/"
  # Masks and props are flat files in the map directory; the source layers are not copied.
  "${RSYNC[@]}" --include 'clip_mask.*' --include '*.glb' --exclude '*' \
    "$SRC/$dir/" "$DEST/$dir/"
done

for file in "${FILES[@]}"; do
  mkdir -p "$DEST/$(dirname "$file")"
  rsync -a "$SRC/$file" "$DEST/$file"
done

# The authored world. `maps.json` plus each map's objects and NPCs — the four things `init`
# used to carry. The agent prompt files and the `*_log.txt` the agents write beside them are
# the server's business and stay out of the app.
mkdir -p "$DEST/data"
rsync -a --include '*/' \
  --include 'maps.json' --include 'objects.json' --include 'npc.json' \
  --exclude '*' --prune-empty-dirs --delete \
  "$DATA/" "$DEST/data/"

echo "[stage] Staged into $DEST ($(du -sh "$DEST" | cut -f1))"
