#!/bin/bash
# DisplayZoomPolicy (Sources/SillHost/DisplayZoomPolicy.swift): larger text while streaming, the rule
# that picks the mode a streamed display switches to (a 27-inch's, a MacBook Air's, a 4K's, displays
# with few modes or none of their shape) and the level the devices and the host's setting want.
# Compiled alone with swiftc (Foundation and CoreGraphics).
#   Tests/checks/display-zoom/run.sh             compile and run the check
here="$(cd "$(dirname "$0")" && pwd)"
source "$here/../common.sh"
rm -f "$out/check"
"$here/build.sh" "$root" "$out/check"
[ -x "$out/check" ] || { echo "$name: did not compile" >&2; exit 1; }
"$out/check"
