#!/bin/zsh
# Build the Swift tools into ./bin
set -e
cd "$(dirname "$0")"
mkdir -p bin
for t in keepalive:preroll-keepalive adump:preroll-latency aplat:aplat apstart:apstart; do
  SRC="${t%%:*}"; OUT="${t##*:}"
  printf 'building %-20s <- src/%s.swift\n' "$OUT" "$SRC"
  swiftc -O "src/$SRC.swift" -o "bin/$OUT" 2>&1 | grep -E '^.*error:' && exit 1 || true
done
echo "built into ./bin"
