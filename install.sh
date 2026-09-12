#!/bin/zsh
# Install Preroll.
set -e
cd "$(dirname "$0")"
LATENCY=${1:-350}
BIN="$HOME/.local/bin"
LABEL=com.ksha23.preroll-keepalive
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"

echo "==> building"
./build.sh

echo "==> installing tools into $BIN"
mkdir -p "$BIN"
cp bin/preroll-keepalive bin/preroll-latency bin/aplat "$BIN/"
cp set-latency-pref.sh apwatch.sh probe_prefs.sh "$BIN/"

echo "==> setting audioLatencyMs = $LATENCY (needs sudo)"
./set-latency-pref.sh audioLatencyMs "$LATENCY"

echo "==> installing LaunchAgent"
mkdir -p "$HOME/Library/LaunchAgents"
sed "s|__HOME__|$HOME|g; s|__LABEL__|$LABEL|g" launchagent.plist.in > "$PLIST"
launchctl unload "$PLIST" 2>/dev/null || true
launchctl load "$PLIST"

echo
echo "==> done. re-select your AirPlay device, then verify:"
echo "    preroll-latency | grep -A3 'DEFAULT OUTPUT'"
echo "    launchctl list | grep airplay"
