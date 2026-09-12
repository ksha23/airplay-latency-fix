#!/bin/zsh
# Set an AirPlay tunable everywhere it might be read, then restart BOTH the
# CoreAudio HAL host and the AirPlay sender helper.
#   usage: set-latency-pref.sh <key> <int|DELETE>
K=$1; V=$2
[ -z "$K" ] && { echo "usage: $0 <key> <int|DELETE>"; exit 1; }
for D in /Library/Preferences/com.apple.airplay /Library/Preferences/com.apple.coremedia; do
  if [ "$V" = "DELETE" ]; then
    sudo defaults delete "$D" "$K" 2>/dev/null && echo "deleted $K from $D"
  else
    sudo defaults write "$D" "$K" -int "$V" && echo "set $K=$V in $D"
  fi
done
if [ "$V" = "DELETE" ]; then
  defaults delete com.apple.airplay "$K" 2>/dev/null
  sudo defaults delete /var/root/Library/Preferences/com.apple.airplay "$K" 2>/dev/null
else
  defaults write com.apple.airplay "$K" -int "$V"
  sudo defaults write /var/root/Library/Preferences/com.apple.airplay "$K" -int "$V" 2>/dev/null
fi
sudo killall cfprefsd 2>/dev/null
sudo killall AirPlayXPCHelper 2>/dev/null && echo "restarted AirPlayXPCHelper"
sudo killall AirPlayUIAgent 2>/dev/null
sudo killall coreaudiod && echo "restarted coreaudiod"
echo "Re-select the HomePods if the output dropped."
