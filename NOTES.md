# Preroll: technical notes

Reference for how macOS AirPlay audio latency works and where the controls live.
Everything here was measured on macOS 26.5.1, Apple Silicon.

## The 2000 ms

`kAudioStreamPropertyLatency` on the AirPlay output device, unmodified:

    AirPlay   transport=airp   44100 Hz   2 ch
    deviceLatency = 0    safetyOffset = 0    streamLatency = 88200    bufferFrames = 512

88200 frames at 44.1 kHz is exactly 2.000 s, the AirTunes constant from 2004.

Note the latency is reported in **stream** scope. `kAudioDevicePropertyLatency` and
`kAudioDevicePropertySafetyOffset` are both zero, so anything summing only
device-scope properties sees 0 ms.

The receiver does not require it. Every stream creation logs:

    Created remote audio stream. arrivalToRenderLatencyMs=84

A HomePod needs 84 ms from packet arrival to render. The other 1916 ms is sender
scheduling policy. A Sonos Era 100 SL and an Apple TV 4K all report the same
88200, confirming the number comes from the sender, not the receiver.

## The control

    domain:  com.apple.airplay
    key:     audioLatencyMs     (integer, milliseconds)

Read by AirPlaySupport inside `/usr/libexec/AirPlayXPCHelper`. Confirmed in the log:

    [com.apple.airplay:APSLatency] Overriding audio latency: 350 ms
    RTAE ['HLA'] AudioEngineRealTime using audio latency 350 ms, audio latency min
                 250 ms, audio latency adjust -250 ms, audio latency offset 0 ms
    RTAE ['HLA'] maxAudioLatency = 15435, maxAudioLatencyAdjust = -11025
    Resuming endpoint stream with latency 0.350000 seconds.

`HLA` is Apple's own label: High Latency Audio.

### Which file to write

`AirPlayXPCHelper` runs as **root**, so its CFPreferences search list resolves
`kCFPreferencesCurrentUser` to `/var/root/Library/Preferences/`, which **outranks**
`/Library/Preferences/`. A value in root's own domain silently wins.

    /var/root/Library/Preferences/com.apple.airplay.plist    highest priority
    /Library/Preferences/com.apple.airplay.plist             lower
    ~/Library/Preferences/com.apple.airplay.plist            never consulted

The console user's own domain is irrelevant. Write root's domain by running
`defaults write com.apple.airplay ...` **as root**; the app writes the system
domain alongside it only so it can read the value back for display.

### When it takes effect

The helper reads the preference when it constructs an audio engine, which happens
when an AirPlay route is established. So:

    route change (deselect/reselect)  ->  picks up the new value
    suspend/resume (play/pause)       ->  does not
    killall AirPlayXPCHelper          ->  works, but drops the route

### Bounds

    audio latency min      250 ms   (stated floor)
    audio latency adjust  -250 ms   (maxAudioLatencyAdjust = -11025 frames)
    audio latency offset     0 ms
    DynamicLatencyManager  variant=B238, latencyTierIdx=0

350 ms was the lowest stable value on the test network. Below that produced
audible problems. Lower latency trades directly against Wi-Fi jitter tolerance.

## Stream renegotiation

With the 2000 ms removed, the remaining cost is that the AirPlay endpoint stream
is suspended whenever audio goes quiet, and a new remote stream is negotiated on
every start:

    audio endpoint stream suspending...
    Resuming endpoint stream with latency 0.350000 seconds
    Created remote audio stream. streamID=<new> arrivalToRenderLatencyMs=84

Measured cost of that renegotiation, against the old 2000 ms baseline:

    cold, after 25 s silence : engine.start() 368.8 ms, first render cb 377.9 ms
    hot, keep-alive running  : engine.start()  95.6 ms, first render cb 105.9 ms
    cold again (control)     : engine.start() 359.5 ms, first render cb 368.5 ms

The keep-alive holds the stream open by feeding continuous inaudible dither at
-78 dBFS. It must be **non-zero** noise, not silence: the HAL driver reads
`enableSilenceDetection` and `enableNonZeroPCMSampleDetection` and logs
`Event: 'Detected non-zero PCM sample'`.

## Preference surface

Extracted with `src/resolve.py`, which resolves CFString operands at the
preference call sites in a Mach-O, applied to
`/System/Library/Audio/Plug-Ins/HAL/AirPlay.driver`, plus the AirPlaySupport
latency table located in the dyld shared cache.

Read by the HAL driver:

| key | reader | notes |
|---|---|---|
| `enableSilenceDetection` | `FigGetCFPreferenceNumberWithDefault`, default 1 | gated behind `_IsAppleInternalBuild`, inert on retail macOS |
| `enableNonZeroPCMSampleDetection` | `APSSettingsGetIntWithDefault` | live, unexplored |
| `mediumLatencyPathway` | `APSSettingsGetIntWithDefault` | **breaks device creation** |
| `fixedIOFrameSize` | `APSSettingsGetIntWithDefault` | works; 1024 froze playback |
| `maxRateOfChange` | `APSSettingsGetDouble` | live, unexplored |
| `HALStreamAudioTapEnabled` | `APSSettingsGetIntWithDefault` | live, unexplored |

The AirPlaySupport latency table:

    audioLatencyMs                "Overriding audio latency: %d ms"
    audioLatencySystemMs          not consulted on this route
    audioLatencyAdjustMs          default -250
    audioLatencyOffsetMs          default 0
    audioLatencyScreenMs / ScreenHighMs / ScreenLowMs
    screenLatencyMs / ForHighLatencyConnectionMs / ForLowLatencyConnectionMs
    mediaPresentationLatencyMs / UDPMs
    mediumLatencyPathwayLatencyMs

### Why mediumLatencyPathway breaks things

It is argument 3 of four to `APSAudioFormatDescriptionListCreateSenderDefaultList`.
Disassembly at 0x4dc0-0x4e08 of the HAL driver:

    4dc0  ldr  w8, [x28, #0x54]        ; device/stream type
    4dc8  cset w24, eq                 ; -> arg 2
    4dcc  adrp x0, "mediumLatencyPathway"
    4dd8  bl   _APSSettingsGetIntWithDefault
    4de0  cset w2, ne                  ; -> arg 3   <<< the pref
    4df0  cset w3, eq                  ; -> arg 4
    4dfc  bl   _APSAudioFormatDescriptionListCreateSenderDefaultList
    4e04  bl   _APSAudioFormatDescriptionListGetFormatCount
    4e08  cbz  x0, 0x4eac              ; count == 0 -> bail

Args 2 and 4 derive from the device type. Setting the preference asks for
low-latency formats on a device created as `DeviceType_Audio`, the format list
comes back empty, and no stream or device is created. Verified to fail identically
on a HomePod pair and an Apple TV 4K.

The device type family, from the GOT bindings:

    DeviceType_Audio            what an audio route always gets
    DeviceType_LowLatencyAudio
    DeviceType_AVConference
    DeviceType_AggrAudio
    DeviceType_Screen
    kAPHALAudioDeviceCreationOption_AudioDeviceType
    kFigEndpointStreamType_LowLatencyAudio   (CoreMedia)

`AudioDeviceType` is a creation option passed by AirPlaySender over XPC. No
preference in the HAL driver controls it.

## The two AirPlay audio engines

AirPlaySender exports both a buffered engine and the realtime one above:

    _APAudioEngineBufferedCreate        _APEndpointStreamBufferedAudioCreate
    _APAudioHoseManagerBufferedCreate   _APAudioEngineBufferedAdapterCreate

Which one is used depends on the content, not on any setting.

- **System audio output is live.** Samples do not exist until produced, so nothing
  can be sent ahead and the receiver's buffer depth *is* the latency. This is the
  realtime engine, and `audioLatencyMs` is the only lever.
- **A media player** hands AirPlay a stream plus a timeline. The receiver
  pre-fetches ahead of the playhead, so buffer depth costs nothing. The
  system-audio route logs the value even while unused:

      Setting media presentation latency to 120 ms and media presentation mode to inactive

Play, pause and seek also differ: realtime means flush then refill, buffered means
re-anchor a timeline.

Consequence: live audio (Discord, Zoom, games, system sounds) can never use the
buffered path. For video, Safari's own player AirPlay button does. See
[lookahead](https://github.com/ksha23/lookahead).

## Why patching was never attempted

SIP and Authenticated Root are enabled and the system boots from a sealed
snapshot. `AirPlaySender` and `AirPlaySupport` have no on-disk binaries; they live
in the dyld shared cache. `coreaudiod` is a platform binary with library
validation. Reaching that code would mean permanently breaking the system security
model, and it is unnecessary: the preference surface is reachable at runtime.

## Privilege design

`SMAppService` and `SMJobBless` both require a real Developer ID, and would make
shipping a bug fix depend on keeping that membership current. A `NOPASSWD` sudoers
rule would remove the prompt but is a standing root grant. Neither is used.

The app writes one root-owned preference file per change, through the standard
macOS authorization dialog, and does nothing else privileged. The keep-alive needs
no privileges at all.
