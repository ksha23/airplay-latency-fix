import CoreAudio
import Foundation

func fourCC(_ v: UInt32) -> String {
    let b = [UInt8((v >> 24) & 0xff), UInt8((v >> 16) & 0xff), UInt8((v >> 8) & 0xff), UInt8(v & 0xff)]
    return String(bytes: b, encoding: .ascii) ?? "\(v)"
}

func getU32(_ dev: AudioObjectID, _ sel: AudioObjectPropertySelector, _ scope: AudioObjectPropertyScope) -> UInt32? {
    var a = AudioObjectPropertyAddress(mSelector: sel, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    var sz = UInt32(MemoryLayout<UInt32>.size); var v: UInt32 = 0
    guard AudioObjectHasProperty(dev, &a) else { return nil }
    return AudioObjectGetPropertyData(dev, &a, 0, nil, &sz, &v) == noErr ? v : nil
}

func getF64(_ dev: AudioObjectID, _ sel: AudioObjectPropertySelector, _ scope: AudioObjectPropertyScope) -> Double? {
    var a = AudioObjectPropertyAddress(mSelector: sel, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    var sz = UInt32(MemoryLayout<Double>.size); var v: Double = 0
    guard AudioObjectHasProperty(dev, &a) else { return nil }
    return AudioObjectGetPropertyData(dev, &a, 0, nil, &sz, &v) == noErr ? v : nil
}

func getStr(_ dev: AudioObjectID, _ sel: AudioObjectPropertySelector, _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> String? {
    var a = AudioObjectPropertyAddress(mSelector: sel, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    var sz = UInt32(MemoryLayout<CFString?>.size); var v: CFString? = nil
    guard AudioObjectHasProperty(dev, &a) else { return nil }
    guard AudioObjectGetPropertyData(dev, &a, 0, nil, &sz, &v) == noErr else { return nil }
    return v as String?
}

var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
var dataSize: UInt32 = 0
AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &dataSize)
let n = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
var devs = [AudioDeviceID](repeating: 0, count: n)
AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &dataSize, &devs)

var defAddr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
var defDev: AudioDeviceID = 0; var dsz = UInt32(MemoryLayout<AudioDeviceID>.size)
AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &defAddr, 0, nil, &dsz, &defDev)

for d in devs {
    // output channel count
    var sa = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreamConfiguration, mScope: kAudioDevicePropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)
    var ssz: UInt32 = 0
    AudioObjectGetPropertyDataSize(d, &sa, 0, nil, &ssz)
    guard ssz > 0 else { continue }
    let bl = UnsafeMutableRawPointer.allocate(byteCount: Int(ssz), alignment: 16)
    defer { bl.deallocate() }
    AudioObjectGetPropertyData(d, &sa, 0, nil, &ssz, bl)
    let abl = bl.assumingMemoryBound(to: AudioBufferList.self)
    var ch = 0
    let buffers = UnsafeBufferPointer(start: &abl.pointee.mBuffers, count: Int(abl.pointee.mNumberBuffers))
    for b in buffers { ch += Int(b.mNumberChannels) }
    guard ch > 0 else { continue }

    let name = getStr(d, kAudioObjectPropertyName) ?? "?"
    let uid  = getStr(d, kAudioDevicePropertyDeviceUID) ?? "?"
    let tt   = getU32(d, kAudioDevicePropertyTransportType, kAudioObjectPropertyScopeGlobal).map { fourCC($0) } ?? "?"
    let sr   = getF64(d, kAudioDevicePropertyNominalSampleRate, kAudioObjectPropertyScopeGlobal) ?? 0
    let bfs  = getU32(d, kAudioDevicePropertyBufferFrameSize, kAudioDevicePropertyScopeOutput) ?? 0
    let lat  = getU32(d, kAudioDevicePropertyLatency, kAudioDevicePropertyScopeOutput) ?? 0
    let safe = getU32(d, kAudioDevicePropertySafetyOffset, kAudioDevicePropertyScopeOutput) ?? 0

    // stream latency
    var stA = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams, mScope: kAudioDevicePropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)
    var stSz: UInt32 = 0
    AudioObjectGetPropertyDataSize(d, &stA, 0, nil, &stSz)
    var streamLat: UInt32 = 0
    if stSz > 0 {
        var streams = [AudioStreamID](repeating: 0, count: Int(stSz) / MemoryLayout<AudioStreamID>.size)
        AudioObjectGetPropertyData(d, &stA, 0, nil, &stSz, &streams)
        if let s = streams.first { streamLat = getU32(s, kAudioStreamPropertyLatency, kAudioObjectPropertyScopeGlobal) ?? 0 }
    }
    let total = Double(lat + safe + streamLat + bfs)
    let ms = sr > 0 ? total / sr * 1000.0 : 0
    let mark = (d == defDev) ? " <== DEFAULT OUTPUT" : ""
    print("\(name)\(mark)")
    print("   uid=\(uid)  transport=\(tt)  outCh=\(ch)  sr=\(Int(sr))")
    print("   bufferFrames=\(bfs)  deviceLatency=\(lat)  safetyOffset=\(safe)  streamLatency=\(streamLat)")
    print("   => reported presentation latency ~= \(String(format: "%.1f", ms)) ms (\(Int(total)) frames)")
    print("")
}
