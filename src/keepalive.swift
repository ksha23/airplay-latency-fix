// preroll-keepalive: hold the macOS AirPlay HAL stream permanently "hot" by feeding
// continuous, inaudible, NON-ZERO dither to the AirPlay output device.
//
// Why non-zero: /System/Library/Audio/Plug-Ins/HAL/AirPlay.driver reads the settings
// `enableSilenceDetection` and `enableNonZeroPCMSampleDetection`, and logs
// "Event: 'Detected non-zero PCM sample'". Digital silence lets the driver idle the
// stream; on resume it must re-establish the session and re-prime the ~2 s receiver
// buffer. Sub-LSB noise keeps every sample non-zero so the stream never idles.

import AVFoundation
import CoreAudio
import Darwin

let kAirPlayTransport: UInt32 = 0x61697270 // 'airp'

var dbfs: Float = -78
var force = false
var verbose = false
var args = Array(CommandLine.arguments.dropFirst())
var i = 0
while i < args.count {
    switch args[i] {
    case "--level":   if i+1 < args.count { dbfs = Float(args[i+1]) ?? dbfs; i += 1 }
    case "--force":   force = true          // run regardless of transport type
    case "--verbose": verbose = true
    case "--help":
        print("""
        preroll-keepalive [--level <dBFS>] [--force] [--verbose]
          --level    dither level in dBFS (default -78; lower = quieter, less robust)
          --force    keep alive even when output is not an AirPlay device
        """)
        exit(0)
    default: break
    }
    i += 1
}
let amp = powf(10, dbfs / 20)

func prop(_ sel: AudioObjectPropertySelector,
          _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal)
-> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(mSelector: sel, mScope: scope,
                               mElement: kAudioObjectPropertyElementMain)
}

func defaultOutput() -> AudioDeviceID {
    var a = prop(kAudioHardwarePropertyDefaultOutputDevice)
    var d: AudioDeviceID = 0
    var sz = UInt32(MemoryLayout<AudioDeviceID>.size)
    AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &sz, &d)
    return d
}

func transport(_ d: AudioDeviceID) -> UInt32 {
    var a = prop(kAudioDevicePropertyTransportType)
    var v: UInt32 = 0
    var sz = UInt32(MemoryLayout<UInt32>.size)
    AudioObjectGetPropertyData(d, &a, 0, nil, &sz, &v)
    return v
}

func name(_ d: AudioDeviceID) -> String {
    var a = prop(kAudioObjectPropertyName)
    var s: CFString? = nil
    var sz = UInt32(MemoryLayout<CFString?>.size)
    let r = withUnsafeMutablePointer(to: &s) {
        AudioObjectGetPropertyData(d, &a, 0, nil, &sz, $0)
    }
    return r == noErr ? (s as String? ?? "?") : "?"
}

func log(_ m: String) {
    let f = DateFormatter(); f.dateFormat = "HH:mm:ss"
    FileHandle.standardError.write("[\(f.string(from: Date()))] \(m)\n".data(using: .utf8)!)
}

final class Keeper {
    private var engine: AVAudioEngine?
    private var seed: UInt32 = 0x9E3779B9
    private(set) var activeOn: AudioDeviceID = 0

    func stop() {
        guard let e = engine else { return }
        e.stop()
        engine = nil
        log("stopped")
        activeOn = 0
    }

    func start(on dev: AudioDeviceID) {
        stop()
        let e = AVAudioEngine()
        // Bind the engine's output to the requested device explicitly.
        var d = dev
        let au = e.outputNode.audioUnit!
        AudioUnitSetProperty(au, kAudioOutputUnitProperty_CurrentDevice,
                             kAudioUnitScope_Global, 0, &d,
                             UInt32(MemoryLayout<AudioDeviceID>.size))
        let fmt = e.outputNode.outputFormat(forBus: 0)
        guard fmt.sampleRate > 0 else { log("no output format; skipping"); return }

        let a = amp
        let src = AVAudioSourceNode(format: fmt) { [weak self] _, _, frames, ablPtr in
            guard let self else { return noErr }
            let abl = UnsafeMutableAudioBufferListPointer(ablPtr)
            for f in 0..<Int(frames) {
                // xorshift32: never returns 0, so every sample is non-zero
                self.seed ^= self.seed << 13
                self.seed ^= self.seed >> 17
                self.seed ^= self.seed << 5
                let v = (Float(self.seed % 2001) - 1000) / 1000 * a
                for buf in abl {
                    guard let p = buf.mData?.assumingMemoryBound(to: Float.self) else { continue }
                    p[f] = v
                }
            }
            return noErr
        }
        e.attach(src)
        e.connect(src, to: e.mainMixerNode, format: fmt)
        e.prepare()
        do {
            try e.start()
            engine = e
            activeOn = dev
            log(String(format: "keep-alive ON  device=%@  %.0f Hz  %d ch  level=%.0f dBFS",
                       name(dev), fmt.sampleRate, fmt.channelCount, dbfs))
        } catch {
            log("failed to start engine: \(error)")
        }
    }
}

let keeper = Keeper()

func evaluate() {
    let dev = defaultOutput()
    guard dev != 0 else { keeper.stop(); return }
    let t = transport(dev)
    let isAir = (t == kAirPlayTransport)
    if verbose {
        let b = withUnsafeBytes(of: t.bigEndian) { Data($0) }
        log("default output = \(name(dev)) transport=\(String(data: b, encoding: .ascii) ?? "?")")
    }
    if isAir || force {
        if keeper.activeOn != dev { keeper.start(on: dev) }
    } else {
        if keeper.activeOn != 0 { log("output is not AirPlay; idling") }
        keeper.stop()
    }
}

var addr = prop(kAudioHardwarePropertyDefaultOutputDevice)
let block: AudioObjectPropertyListenerBlock = { _, _ in
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { evaluate() }
}
AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject),
                                    &addr, DispatchQueue.main, block)

signal(SIGINT)  { _ in keeper.stop(); exit(0) }
signal(SIGTERM) { _ in keeper.stop(); exit(0) }

log("preroll-keepalive started (level \(dbfs) dBFS)")
evaluate()
// Re-check periodically: AirPlay devices appear/disappear from CoreAudio on selection.
Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { _ in evaluate() }
RunLoop.main.run()
