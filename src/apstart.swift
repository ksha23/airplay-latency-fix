// apstart: measure how long it takes to get audio actually flowing on the current
// output device: engine.start() -> first render callback -> first callback whose
// AudioTimeStamp is live. Run cold, then again with preroll-keepalive running.
import AVFoundation
import CoreAudio

var tb = mach_timebase_info_data_t(); mach_timebase_info(&tb)
@inline(__always) func ms(_ a: UInt64, _ b: UInt64) -> Double {
    Double(b &- a) * Double(tb.numer) / Double(tb.denom) / 1_000_000.0
}

func prop(_ s: AudioObjectPropertySelector, _ sc: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal)
-> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(mSelector: s, mScope: sc, mElement: kAudioObjectPropertyElementMain)
}
func defaultOutput() -> AudioDeviceID {
    var a = prop(kAudioHardwarePropertyDefaultOutputDevice); var d: AudioDeviceID = 0
    var sz = UInt32(MemoryLayout<AudioDeviceID>.size)
    AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &sz, &d); return d
}
func name(_ d: AudioDeviceID) -> String {
    var a = prop(kAudioObjectPropertyName); var s: CFString? = nil
    var sz = UInt32(MemoryLayout<CFString?>.size)
    let r = withUnsafeMutablePointer(to: &s) { AudioObjectGetPropertyData(d, &a, 0, nil, &sz, $0) }
    return r == noErr ? (s as String? ?? "?") : "?"
}
func streamLatency(_ d: AudioDeviceID) -> UInt32 {
    var a = prop(kAudioDevicePropertyStreams, kAudioDevicePropertyScopeOutput); var sz: UInt32 = 0
    AudioObjectGetPropertyDataSize(d, &a, 0, nil, &sz); guard sz > 0 else { return 0 }
    var st = [AudioStreamID](repeating: 0, count: Int(sz)/MemoryLayout<AudioStreamID>.size)
    AudioObjectGetPropertyData(d, &a, 0, nil, &sz, &st); guard let s = st.first else { return 0 }
    var la = prop(kAudioStreamPropertyLatency); var v: UInt32 = 0
    var vs = UInt32(MemoryLayout<UInt32>.size)
    AudioObjectGetPropertyData(s, &la, 0, nil, &vs, &v); return v
}

let dev = defaultOutput()
print("device      : \(name(dev))")
print("streamLatency: \(streamLatency(dev)) frames")

let engine = AVAudioEngine()
var d = dev
AudioUnitSetProperty(engine.outputNode.audioUnit!, kAudioOutputUnitProperty_CurrentDevice,
                     kAudioUnitScope_Global, 0, &d, UInt32(MemoryLayout<AudioDeviceID>.size))
let fmt = engine.outputNode.outputFormat(forBus: 0)
print("format      : \(Int(fmt.sampleRate)) Hz, \(fmt.channelCount) ch")

var firstCB: UInt64 = 0
var cbCount = 0
let sem = DispatchSemaphore(value: 0)
var phase: Float = 0
let inc = 2 * Float.pi * 660 / Float(fmt.sampleRate)

let src = AVAudioSourceNode(format: fmt) { _, ts, frames, ablPtr in
    if firstCB == 0 { firstCB = mach_absolute_time(); sem.signal() }
    cbCount += 1
    let abl = UnsafeMutableAudioBufferListPointer(ablPtr)
    for f in 0..<Int(frames) {
        phase += inc; if phase > 2 * .pi { phase -= 2 * .pi }
        let v = sinf(phase) * 0.06            // quiet 660 Hz test tone
        for b in abl { b.mData?.assumingMemoryBound(to: Float.self)[f] = v }
    }
    return noErr
}
engine.attach(src)
engine.connect(src, to: engine.mainMixerNode, format: fmt)
engine.prepare()

let t0 = mach_absolute_time()
do { try engine.start() } catch { print("start failed: \(error)"); exit(1) }
let t1 = mach_absolute_time()
print(String(format: "engine.start() returned after : %8.2f ms", ms(t0, t1)))
_ = sem.wait(timeout: .now() + 15)
if firstCB == 0 { print("no render callback within 15 s") }
else { print(String(format: "first render callback after   : %8.2f ms", ms(t0, firstCB))) }
Thread.sleep(forTimeInterval: 2.5)
print("callbacks in 2.5 s: \(cbCount)")
engine.stop()
