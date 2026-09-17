#!/usr/bin/env bash
# Render recorded casts to animated GIFs for docs and posts.
#
#   ./demo/render.sh                    # every cast in demo/casts
#   ./demo/render.sh 02-agent-sandbox   # just one
#
# Uses agg (https://github.com/asciinema/agg). GIFs land next to the casts as
# demo/casts/<name>.gif and are gitignored like the casts. Idle time is
# already capped at record time, so the GIF length matches playback.
set -eu -o pipefail

repo_root=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
cd "$repo_root"

command -v agg >/dev/null 2>&1 || {
  echo "agg is required: brew install agg (or cargo install --git https://github.com/asciinema/agg)" >&2
  exit 1
}

if [ $# -gt 0 ]; then
  names=$*
else
  names=$(cd demo/casts && ls *.cast | sed 's/\.cast$//' | tr '\n' ' ')
fi

for name in $names; do
  cast=demo/casts/$name.cast
  test -f "$cast" || {
    echo "no such cast: $cast" >&2
    exit 1
  }
  echo "==> rendering $name"
  agg "$cast" "demo/casts/$name.gif" \
    --cols 100 --rows 28 \
    --font-size 16 \
    --theme monokai \
    --speed "${RENDER_SPEED:-1.0}" \
    --last-frame-duration 3 2>&1 | tr "\r" "\n" | tail -n 1
done
