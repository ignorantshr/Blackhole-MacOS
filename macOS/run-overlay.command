#!/bin/zsh
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p .build
if [[ ! -x .build/BlackHoleOverlay || BlackHoleOverlay.swift -nt .build/BlackHoleOverlay ]]; then
  swiftc -parse-as-library -O -module-cache-path /tmp/blackhole-screen-module-cache -framework Cocoa -framework Carbon BlackHoleOverlay.swift -o .build/BlackHoleOverlay
fi
exec .build/BlackHoleOverlay
