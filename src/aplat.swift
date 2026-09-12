// aplat: true end-to-end acoustic latency of the current output device.
// Emits a short tone burst, listens on the built-in mic, reports the delta.
// --stop  : stop/restart the output engine between bursts (emulates Firefox pause/resume)
// --gap N : seconds of silence between bursts (lets the AirPlay stream idle)
import AVFoundation
import CoreAudio

var tb = mach_timebase_info_data_t(); mach_timebase_info(&tb)
@inline(__always) func toMs(_ d: UInt64) -> Double { Double(d) * Double(tb.numer)/Double(tb.denom)/1e6 }
@inline(__always) func nowHT() -> UInt64 { mach_absolute_time() }
func htAdd(_ ht: UInt64, seconds: Double) -> UInt64 {
    ht &+ UInt64(seconds * 1e9 * Double(tb.denom) / Double(tb.numer))
}

var gap = 6.0, reps = 4; var stopBetween = false
var a = Array(CommandLine.arguments.dropFirst()); var i = 0
while i < a.count {
    switch a[i] {
    case "--gap":  if i+1 < a.count { gap = Double(a[i+1]) ?? gap; i += 1 }
    case "--reps": if i+1 < a.count { reps = Int(a[i+1]) ?? reps; i += 1 }
    case "--stop": stopBetween = true
    default: break
    }; i += 1
}

func prop(_ s: AudioObjectPropertySelector, _ sc: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal)
-> AudioObjectPropertyAddress { AudioObjectPropertyAddress(mSelector: s, mScope: sc, mElement: kAudioObjectPropertyElementMain) }
func devID(_ sel: AudioObjectPropertySelector) -> AudioDeviceID {
    var ad = prop(sel); var d: AudioDeviceID = 0; var sz = UInt32(MemoryLayout<AudioDeviceID>.size)
    AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &ad, 0, nil, &sz, &d); return d
}
func devName(_ d: AudioDeviceID) -> String {
    var ad = prop(kAudioObjectPropertyName); var s: CFString? = nil
    var sz = UInt32(MemoryLayout<CFString?>.size)
    let r = withUnsafeMutablePointer(to: &s) { AudioObjectGetPropertyData(d, &ad, 0, nil, &sz, $0) }
    return r == noErr ? (s as String? ?? "?") : "?"
}

let outDev = devID(kAudioHardwarePropertyDefaultOutputDevice)
let inDev  = devID(kAudioHardwarePropertyDefaultInputDevice)
print("output : \(devName(outDev))")
print("input  : \(devName(inDev))")

let sema = DispatchSemaphore(value: 0)
AVCaptureDevice.requestAccess(for: .audio) { ok in
    if !ok { print("MIC DENIED. Grant Terminal microphone access in System Settings > Privacy & Security > Microphone.") ; exit(2) }
    sema.signal()
}
_ = sema.wait(timeout: .now() + 30)

// ---------- input ----------
let inEngine = AVAudioEngine()
var idev = inDev
AudioUnitSetProperty(inEngine.inputNode.audioUnit!, kAudioOutputUnitProperty_CurrentDevice,
                     kAudioUnitScope_Global, 0, &idev, UInt32(MemoryLayout<AudioDeviceID>.size))
let inFmt = inEngine.inputNode.outputFormat(forBus: 0)
let F0: Double = 3000

final class Det {
    var armedAt: UInt64 = 0          // host time the burst entered the output pipeline
    var detected: UInt64 = 0
    var armed = false
    let q = DispatchQueue(label: "det")
    var floorMag: Double = 0
    func arm(_ t: UInt64) { q.sync { armedAt = t; detected = 0; armed = true } }
    func disarm() { q.sync { armed = false } }
}
let det = Det()

inEngine.inputNode.installTap(onBus: 0, bufferSize: 512, format: inFmt) { buf, when in
    guard let ch = buf.floatChannelData?[0] else { return }
    let n = Int(buf.frameLength); let sr = inFmt.sampleRate
    let block = 128
    let w = 2.0 * Double.pi * F0 / sr, coeff = 2.0 * cos(w)
    var b = 0
    while b + block <= n {
        var s0 = 0.0, s1 = 0.0, s2 = 0.0
        for k in 0..<block { s0 = Double(ch[b+k]) + coeff*s1 - s2; s2 = s1; s1 = s0 }
        let mag = sqrt(s1*s1 + s2*s2 - coeff*s1*s2) / Double(block)
        det.q.sync {
            if !det.armed { det.floorMag = det.floorMag * 0.95 + mag * 0.05 }
            else if det.detected == 0 && mag > max(det.floorMag * 12, 0.002) {
                let off = Double(b) / sr
                det.detected = htAdd(when.hostTime, seconds: off)
                det.armed = false
            }
        }
        b += block
    }
}
try? inEngine.start()
Thread.sleep(forTimeInterval: 1.2)   // settle + learn noise floor
print(String(format: "noise floor mag: %.5f", det.floorMag))

// ---------- output ----------
var burstRemaining = 0, burstPhase: Float = 0
let burstLock = NSLock()
var outEngine: AVAudioEngine!
var srcFmt: AVAudioFormat!

func buildOut() {
    outEngine = AVAudioEngine()
    var od = outDev
    AudioUnitSetProperty(outEngine.outputNode.audioUnit!, kAudioOutputUnitProperty_CurrentDevice,
                         kAudioUnitScope_Global, 0, &od, UInt32(MemoryLayout<AudioDeviceID>.size))
    srcFmt = outEngine.outputNode.outputFormat(forBus: 0)
    let inc = 2 * Float.pi * Float(F0) / Float(srcFmt.sampleRate)
    let node = AVAudioSourceNode(format: srcFmt) { _, _, frames, ablPtr in
        let abl = UnsafeMutableAudioBufferListPointer(ablPtr)
        burstLock.lock(); let rem = burstRemaining; burstLock.unlock()
        if rem > 0 && det.armedAt == 0 { det.q.sync { det.armedAt = nowHT() } }
        for f in 0..<Int(frames) {
            var v: Float = 0
            burstLock.lock()
            if burstRemaining > 0 { burstPhase += inc; v = sinf(burstPhase) * 0.30; burstRemaining -= 1 }
            burstLock.unlock()
            for b in abl { b.mData?.assumingMemoryBound(to: Float.self)[f] = v }
        }
        return noErr
    }
    outEngine.attach(node)
    outEngine.connect(node, to: outEngine.mainMixerNode, format: srcFmt)
    outEngine.prepare()
}
buildOut(); try? outEngine.start()
print(String(format: "output format: %.0f Hz\n", srcFmt.sampleRate))

var results: [Double] = []
for r in 1...reps {
    if stopBetween && r > 1 { buildOut(); try? outEngine.start() }
    det.q.sync { det.armedAt = 0; det.detected = 0; det.armed = true }
    burstLock.lock(); burstPhase = 0; burstRemaining = Int(srcFmt.sampleRate * 0.08); burstLock.unlock()
    var got: UInt64 = 0; var t0: UInt64 = 0
    let deadline = Date().addingTimeInterval(8)
    while Date() < deadline {
        var d: UInt64 = 0; var s: UInt64 = 0
        det.q.sync { d = det.detected; s = det.armedAt }
        if d != 0 && s != 0 { got = d; t0 = s; break }
        usleep(2000)
    }
    if got != 0 {
        let ms = toMs(got &- t0); results.append(ms)
        print(String(format: "burst %d: %8.1f ms", r, ms))
    } else { print("burst \(r): NOT DETECTED (raise volume / move closer)") }
    if stopBetween { outEngine.stop() }
    if r < reps { Thread.sleep(forTimeInterval: gap) }
}
if !results.isEmpty {
    let mean = results.reduce(0,+)/Double(results.count)
    print(String(format: "\nmean %.1f ms   min %.1f   max %.1f",
                 mean, results.min()!, results.max()!))
}
inEngine.stop(); outEngine.stop()
