#!/bin/zsh
# Determine WHICH preference file coreaudiod actually reads, by watching its
# filesystem access as it restarts. Definitive answer to the APSSettings domain question.
OUT=${1:-/tmp/coreaudiod_prefs.txt}
echo "Starting fs_usage probe; restarting coreaudiod..."
sudo fs_usage -w -f filesys coreaudiod 2>/dev/null | grep -iE 'plist|preferences' > "$OUT" &
FS=$!
sleep 1
sudo killall coreaudiod
sleep 4
sudo kill $FS 2>/dev/null
echo "--- preference files coreaudiod touched ---"
sed -E 's/.*(\/[^ ]*\.plist).*/\1/' "$OUT" | grep '^/' | sort -u
echo "--- raw (first 40) ---"
head -40 "$OUT"
