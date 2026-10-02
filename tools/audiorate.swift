// audiorate (2026-10-02) -- see and set macOS audio device sample rates without Audio MIDI Setup.
//   audiorate                          list devices: rate, rates it supports, channels, default in/out, Multi-Output members + clock
//   audiorate set "<name>" 48000       set a device's rate (name = prefix or substring, case-insensitive)
//   audiorate input "<name>"           make a device the system default INPUT (e.g. "MacBook Pro Microphone": an AirPods
//                                      pair that is the default input drops into call mode, 24 kHz in / 32 kHz out)
//   audiorate output "<name>"          make a device the system default OUTPUT
//   audiorate rig [rate]               the Supra-Organism setup: default input = MacBook Pro Microphone, Fireface and
//                                      Multi-Output Device (+ members) -> rate (default 44100), then list
//   audiorate rates "<name>"           the rates a device offers right now
// Build: swiftc -O audiorate.swift -o ~/.local/bin/audiorate
import CoreAudio
import Foundation

let SYS = AudioObjectID(kAudioObjectSystemObject)
func addr(_ s: AudioObjectPropertySelector, _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(mSelector: s, mScope: scope, mElement: kAudioObjectPropertyElementMain) }
func ids(_ obj: AudioObjectID, _ sel: AudioObjectPropertySelector) -> [AudioObjectID] {
    var a = addr(sel); var sz: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(obj, &a, 0, nil, &sz) == noErr, sz > 0 else { return [] }
    var out = [AudioObjectID](repeating: 0, count: Int(sz) / MemoryLayout<AudioObjectID>.size)
    AudioObjectGetPropertyData(obj, &a, 0, nil, &sz, &out); return out }
func str(_ obj: AudioObjectID, _ sel: AudioObjectPropertySelector) -> String {
    var a = addr(sel); var v: CFString? = nil; var sz = UInt32(MemoryLayout<CFString?>.size)
    let r = withUnsafeMutablePointer(to: &v) { AudioObjectGetPropertyData(obj, &a, 0, nil, &sz, $0) }
    return r == noErr ? (v as String? ?? "?") : "?" }
func rate(_ d: AudioObjectID) -> Double { var a = addr(kAudioDevicePropertyNominalSampleRate); var v = Float64(0); var sz = UInt32(8)
    AudioObjectGetPropertyData(d, &a, 0, nil, &sz, &v); return v }
func rates(_ d: AudioObjectID) -> [Double] {
    var a = addr(kAudioDevicePropertyAvailableNominalSampleRates); var sz: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(d, &a, 0, nil, &sz) == noErr, sz > 0 else { return [] }
    var r = [AudioValueRange](repeating: AudioValueRange(), count: Int(sz) / MemoryLayout<AudioValueRange>.size)
    AudioObjectGetPropertyData(d, &a, 0, nil, &sz, &r); return r.map { $0.mMinimum } }
func chans(_ d: AudioObjectID, _ scope: AudioObjectPropertyScope) -> Int {
    var a = addr(kAudioDevicePropertyStreamConfiguration, scope); var sz: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(d, &a, 0, nil, &sz) == noErr, sz > 0 else { return 0 }
    let buf = UnsafeMutableRawPointer.allocate(byteCount: Int(sz), alignment: 16); defer { buf.deallocate() }
    AudioObjectGetPropertyData(d, &a, 0, nil, &sz, buf)
    return UnsafeMutableAudioBufferListPointer(buf.assumingMemoryBound(to: AudioBufferList.self)).reduce(0) { $0 + Int($1.mNumberChannels) } }
func dflt(_ sel: AudioObjectPropertySelector) -> AudioObjectID { var a = addr(sel); var v = AudioObjectID(0); var sz = UInt32(4)
    AudioObjectGetPropertyData(SYS, &a, 0, nil, &sz, &v); return v }
func devices() -> [AudioObjectID] { ids(SYS, kAudioHardwarePropertyDevices) }
func name(_ d: AudioObjectID) -> String { str(d, kAudioObjectPropertyName) }
func find(_ q: String, wantIn: Bool? = nil) -> AudioObjectID? {
    let ql = q.lowercased(); let ds = devices().filter { d in
        guard let w = wantIn else { return true }; return chans(d, w ? kAudioObjectPropertyScopeInput : kAudioObjectPropertyScopeOutput) > 0 }
    return ds.first { name($0).lowercased().hasPrefix(ql) } ?? ds.first { name($0).lowercased().contains(ql) } }
func setRate(_ d: AudioObjectID, _ r: Double) -> Bool {
    var a = addr(kAudioDevicePropertyNominalSampleRate); var v = Float64(r)
    let st = AudioObjectSetPropertyData(d, &a, 0, nil, 8, &v)
    for _ in 0..<30 { if rate(d) == r { break }; usleep(100_000) }   // the change lands asynchronously
    let ok = st == noErr && rate(d) == r
    print("\(name(d)): \(ok ? "now" : "FAILED, still") \(Int(rate(d))) Hz" + (ok ? "" : "  (supports: \(rates(d).map { Int($0) }); a Bluetooth headset in call mode only offers 16-32 k)"))
    return ok }
func setDefault(_ sel: AudioObjectPropertySelector, _ d: AudioObjectID, _ what: String) {
    var a = addr(sel); var v = d; let st = AudioObjectSetPropertyData(SYS, &a, 0, nil, 4, &v)
    print("default \(what): \(st == noErr ? name(d) : "FAILED (\(st))")") }
func list() {
    let di = dflt(kAudioHardwarePropertyDefaultInputDevice), dout = dflt(kAudioHardwarePropertyDefaultOutputDevice)
    for d in devices() {
        let i = chans(d, kAudioObjectPropertyScopeInput), o = chans(d, kAudioObjectPropertyScopeOutput)
        var tags: [String] = []; if d == di { tags.append("DEFAULT IN") }; if d == dout { tags.append("DEFAULT OUT") }
        let av = rates(d).map { String(Int($0 / 1000)) }.joined(separator: "/")
        print("\(name(d).padding(toLength: 40, withPad: " ", startingAt: 0)) \(String(format: "%6d", Int(rate(d)))) Hz  in \(String(format: "%2d", i))  out \(String(format: "%2d", o))  offers \(av)k  \(tags.joined(separator: ", "))")
        let subs = ids(d, kAudioAggregateDevicePropertyActiveSubDeviceList)
        if !subs.isEmpty {
            let clock = str(d, kAudioAggregateDevicePropertyMainSubDevice)
            for s in subs { let isClock = str(s, kAudioDevicePropertyDeviceUID) == clock
                print("      member: \(name(s))  \(Int(rate(s))) Hz\(isClock ? "  <- clock" : "")") }
        }
    }
}
let args = Array(CommandLine.arguments.dropFirst())
switch args.first ?? "list" {
case "list": list()
case "rates":   // the rates a device offers right now (a Multi-Output only offers what EVERY member can do)
    guard args.count == 2, let d = find(args[1]) else { print("usage: audiorate rates \"<device name>\""); exit(2) }
    print(rates(d).map { String(Int($0)) }.joined(separator: " "))
case "set":
    guard args.count == 3, let r = Double(args[2]), let d = find(args[1]) else { print("usage: audiorate set \"<device name>\" 48000"); exit(2) }
    exit(setRate(d, r) ? 0 : 1)
case "input":
    guard args.count == 2, let d = find(args[1], wantIn: true) else { print("no input device matches"); exit(2) }
    setDefault(kAudioHardwarePropertyDefaultInputDevice, d, "input")
case "output":
    guard args.count == 2, let d = find(args[1], wantIn: false) else { print("no output device matches"); exit(2) }
    setDefault(kAudioHardwarePropertyDefaultOutputDevice, d, "output")
case "rig":   // audiorate rig [rate]  (default 44100, the rig's rate since 2026-10-02: Bluetooth members offer 44.1 k even in call mode)
    // no rate given = AUTO (2026-10-02): the best rate BOTH the Multi-Output Device (= every in-ear member) and the Fireface
    // offer right now, 48 k first, then 44.1 k. Bluetooth members change what they offer when they fall into call mode.
    if let m = find("MacBook Pro Microphone", wantIn: true) { setDefault(kAudioHardwarePropertyDefaultInputDevice, m, "input") }
    usleep(1_500_000)
    var R = 48000.0
    if args.count > 1, let r = Double(args[1]) { R = r } else {
        let mo = find("Multi-Output").map(rates) ?? [], ff = find("Fireface").map(rates) ?? []
        let both = [48000.0, 44100.0].filter { mo.contains($0) && ff.contains($0) }
        R = both.first ?? 48000
        print("auto: Multi-Output offers \(mo.map { Int($0) }), Fireface offers \(ff.map { Int($0) }) -> \(Int(R))" + (both.isEmpty ? "  (NO shared rate: an in-ear member is in call mode; the lav will be off)" : ""))
    }
    var ok = true
    if let f = find("Fireface") { ok = setRate(f, R) && ok } else { print("Fireface: not connected"); ok = false }
    usleep(1_500_000)   // a headset leaves call mode a moment after its mic is released
    if let mo = find("Multi-Output") {
        for s in ids(mo, kAudioAggregateDevicePropertyActiveSubDeviceList) where rate(s) != R { ok = setRate(s, R) && ok }
        ok = setRate(mo, R) && ok
    } else { print("Multi-Output Device: not found"); ok = false }
    print(""); list(); print("RIG RATE \(Int(R))"); exit(ok ? 0 : 1)
default: print("usage: audiorate [list | set \"<name>\" <Hz> | input \"<name>\" | output \"<name>\" | rig]"); exit(2)
}
