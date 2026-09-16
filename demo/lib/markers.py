#!/usr/bin/env python3
"""Turn OrkaMarker sentinels in an asciicast v3 recording into marker events.

demo/lib/demo.sh writes `ESC ] 1337 ; OrkaMarker=<label> BEL` at the start of
each chapter. Terminals swallow the sequence, but asciinema records it. This
rewrites each occurrence into an asciicast v3 marker event -- `[0.0, "m",
"<label>"]` -- and removes the sentinel from the output stream, so
`asciinema play --pause-on-markers` can pause at every chapter and `]` skips
to the next one.

Intervals in v3 are relative, so splitting one output event into
text/marker/text costs no timing fixup: the leading fragment keeps the
original interval and everything after it gets 0.0.

usage: markers.py <cast-file>   (rewritten in place)
"""

import json
import re
import sys

SENTINEL = re.compile(r"\x1b\]1337;OrkaMarker=([^\x07\x1b]*)\x07")


def rewrite(lines):
    out = []
    for index, line in enumerate(lines):
        stripped = line.strip()
        if index == 0 or not stripped:
            out.append(line)
            continue
        event = json.loads(stripped)
        if len(event) < 3 or event[1] != "o" or "OrkaMarker=" not in event[2]:
            out.append(line)
            continue

        interval, data = event[0], event[2]
        parts = SENTINEL.split(data)
        pending = interval
        for position, part in enumerate(parts):
            if position % 2 == 0:
                if not part:
                    continue
                out.append(json.dumps([pending, "o", part]) + "\n")
            else:
                out.append(json.dumps([pending, "m", part]) + "\n")
            pending = 0.0
    return out


def main():
    if len(sys.argv) != 2:
        raise SystemExit("usage: markers.py <cast-file>")
    path = sys.argv[1]
    with open(path, encoding="utf-8") as handle:
        lines = handle.readlines()
    if not lines:
        raise SystemExit(f"empty recording: {path}")

    header = json.loads(lines[0])
    if header.get("version") != 3:
        raise SystemExit(f"expected an asciicast v3 recording, got version {header.get('version')!r}")

    rewritten = rewrite(lines)
    markers = sum(1 for line in rewritten[1:] if line.strip() and json.loads(line.strip())[1] == "m")

    with open(path, "w", encoding="utf-8") as handle:
        handle.writelines(rewritten)
    print(f"{path}: {markers} marker(s)")


if __name__ == "__main__":
    main()
