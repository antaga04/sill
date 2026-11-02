#!/bin/bash
# usage: build.sh ROOT OUT [DisplayZoomPolicy.swift override]
# Compiles Sources/SillHost/DisplayZoomPolicy.swift (Foundation and CoreGraphics only) with this
# check's main.swift. Nothing else of the host: no display is read or switched.
ROOT=$1; OUT=$2; T=$(mktemp -d)
cp "${3:-$ROOT/Sources/SillHost/DisplayZoomPolicy.swift}" "$T/DisplayZoomPolicy.swift"
cp "$(dirname "$0")/main.swift" "$T/main.swift"
swiftc -O -package-name sill "$T"/*.swift -o "$OUT" 2>&1 | grep -E "error" ; rm -rf "$T"
