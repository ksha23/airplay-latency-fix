#!/bin/zsh
# Revert everything Preroll changed.
cd "$(dirname "$0")"
LABEL=com.ksha23.preroll-keepalive
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
echo "==> unloading LaunchAgent"
launchctl unload "$PLIST" 2>/dev/null || true
rm -f "$PLIST"
echo "==> removing the preference (restores the 2 s default)"
./set-latency-pref.sh audioLatencyMs DELETE
echo "==> removing tools"
rm -f "$HOME/.local/bin/preroll-keepalive" "$HOME/.local/bin/preroll-latency" \
      "$HOME/.local/bin/aplat" "$HOME/.local/bin/set-latency-pref.sh" \
      "$HOME/.local/bin/apwatch.sh" "$HOME/.local/bin/probe_prefs.sh"
echo "==> done. re-select your AirPlay device."
