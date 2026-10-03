// audiokeepalive "<output device name>" [dBFS]   (2026-10-02)
// Plays pink noise at a very low level (default -70 dBFS) to ONE output device, found by name among devices that have outputs
// (the BTD 700 also shows up as an input with the same name, which is what tripped sox). Keeps a Bluetooth / Auracast dongle
// broadcasting so the headphones stay joined. Exits (status 1) if the device is missing or goes away, so a wrapper loop
// (btd_keepalive.sh) can start it again when the device returns.
// Build: swiftc -O audiokeepalive.swift -o ~/.local/bin/audiokeepalive
import AVFoundation
import CoreAudio

func addr(_ s: AudioObjectPropertySelector, _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(mSelector: s, mScope: scope, mElement: kAudioObjectPropertyElementMain) }
func devices() -> [AudioObjectID] {
    var a = addr(kAudioHardwarePropertyDevices); var sz: UInt32 = 0
    AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &sz)
    var ids = [AudioObjectID](repeating: 0, count: Int(sz) / 4); AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &sz, &ids); return ids }
func name(_ d: AudioObjectID) -> String {
    var a = addr(kAudioObjectPropertyName); var v: CFString? = nil; var sz = UInt32(MemoryLayout<CFString?>.size)
    _ = withUnsafeMutablePointer(to: &v) { AudioObjectGetPropertyData(d, &a, 0, nil, &sz, $0) }; return (v as String?) ?? "" }
func outChannels(_ d: AudioObjectID) -> Int {
    var a = addr(kAudioDevicePropertyStreamConfiguration, kAudioObjectPropertyScopeOutput); var sz: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(d, &a, 0, nil, &sz) == noErr, sz > 0 else { return 0 }
    let buf = UnsafeMutableRawPointer.allocate(byteCount: Int(sz), alignment: 16); defer { buf.deallocate() }
    AudioObjectGetPropertyData(d, &a, 0, nil, &sz, buf)
    return UnsafeMutableAudioBufferListPointer(buf.assumingMemoryBound(to: AudioBufferList.self)).reduce(0) { $0 + Int($1.mNumberChannels) } }

let args = CommandLine.arguments
let want = args.count > 1 ? args[1] : "BTD 700"; let db = args.count > 2 ? (Double(args[2]) ?? -70) : -70
guard let dev = devices().first(where: { name($0).lowercased().hasPrefix(want.lowercased()) && outChannels($0) > 0 }) else {
    FileHandle.standardError.write("audiokeepalive: no output device named '\(want)'\n".data(using: .utf8)!); exit(1) }

let engine = AVAudioEngine()
var devID = dev
let unit = engine.outputNode.audioUnit!
if AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &devID, UInt32(MemoryLayout<AudioObjectID>.size)) != noErr {
    FileHandle.standardError.write("audiokeepalive: could not select '\(want)'\n".data(using: .utf8)!); exit(1) }
let fmt = engine.outputNode.outputFormat(forBus: 0)
let gain = Float(pow(10, db / 20)) * 4    // Voss-McCartney sum of 4 rows peaks ~4x a single row: scale so RMS sits near the target
var rows = [Float](repeating: 0, count: 8); var counter: UInt32 = 0; var running: Float = 0
let src = AVAudioSourceNode { _, _, frames, abl -> OSStatus in
    let bufs = UnsafeMutableAudioBufferListPointer(abl)
    for f in 0..<Int(frames) {
        counter &+= 1; let k = min(7, counter.trailingZeroBitCount)                 // pink noise: Voss-McCartney
        running -= rows[k]; rows[k] = Float.random(in: -1...1) / 8; running += rows[k]
        let s = (running + Float.random(in: -1...1) / 8) * gain / 4
        for b in bufs { b.mData!.assumingMemoryBound(to: Float.self)[f] = s }
    }
    return noErr }
engine.attach(src); engine.connect(src, to: engine.mainMixerNode, format: AVAudioFormat(standardFormatWithSampleRate: fmt.sampleRate, channels: max(1, fmt.channelCount)))
do { try engine.start() } catch { FileHandle.standardError.write("audiokeepalive: start failed: \(error)\n".data(using: .utf8)!); exit(1) }
print("audiokeepalive: '\(name(dev))' at \(Int(fmt.sampleRate)) Hz, \(fmt.channelCount) ch, pink noise ~\(Int(db)) dBFS"); fflush(stdout)

// leave when the device goes away (or the engine stops), so the wrapper restarts us when it is back
var aliveAddr = addr(kAudioDevicePropertyDeviceIsAlive)
Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { _ in
    var alive: UInt32 = 0; var sz = UInt32(4)
    let ok = AudioObjectGetPropertyData(dev, &aliveAddr, 0, nil, &sz, &alive) == noErr && alive != 0
    if !ok || !engine.isRunning { print("audiokeepalive: '\(want)' gone or stopped -- exiting"); fflush(stdout); exit(1) } }
NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil) { _ in
    print("audiokeepalive: device configuration changed -- exiting to restart"); fflush(stdout); exit(1) }
RunLoop.main.run()
