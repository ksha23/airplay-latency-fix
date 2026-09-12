#!/bin/zsh
# NOTE: zsh has a `log` BUILTIN that takes no args and shadows /usr/bin/log.
# Always call the absolute path here.
PRED='(process == "coreaudiod" OR process == "AirPlayXPCHelper" OR process == "AirPlayUIAgent" OR process == "mediaremoted") AND (eventMessage CONTAINS[c] "overriding" OR eventMessage CONTAINS[c] "latency" OR eventMessage CONTAINS "BufferFrameSize" OR eventMessage CONTAINS "non-zero PCM" OR eventMessage CONTAINS "endpoint stream" OR eventMessage CONTAINS[c] "cluster model")'
echo "Watching coreaudiod + AirPlayXPCHelper + AirPlayUIAgent + mediaremoted."
echo "KEY LINE TO LOOK FOR:  Overriding system audio latency: 500 ms"
echo "-------------------------------------------------------------------"
exec /usr/bin/log stream --style compact --level debug --predicate "$PRED"
