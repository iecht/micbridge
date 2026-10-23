// MicBridge Receiver — runs on the Mac mini.
// Watches whether any app is recording from the BlackHole virtual device.
// It keeps a connection to the sender on the MacBook Air open at all times; when an
// app records, it asks the Air to switch its microphone on and plays the incoming
// audio into BlackHole, so the app hears the Air's mic. When recording stops, it
// asks the Air to switch the microphone off again.

import AVFoundation
import CoreAudio
import Foundation
import Network

setvbuf(stdout, nil, _IOLBF, 0)

func log(_ msg: String) {
    let f = DateFormatter()
    f.dateFormat = "HH:mm:ss"
    print("[\(f.string(from: Date()))] \(msg)")
}

let serviceType = "_micbridge._tcp"
var host: String?
var port: UInt16 = 50555
var deviceMatch = "BlackHole"
var alwaysOn = false
var setDefault = true
var args = CommandLine.arguments.dropFirst().makeIterator()
while let a = args.next() {
    switch a {
    case "--host": host = args.next()
    case "--port": port = UInt16(args.next() ?? "") ?? port
    case "--device": deviceMatch = args.next() ?? deviceMatch
    case "--always-on": alwaysOn = true
    case "--no-set-default": setDefault = false
    default:
        print("""
        usage: micbridge-receiver [--host IP] [--port N] [--device NAME] [--always-on] [--no-set-default]
          --host        connect to this address instead of finding the Air via Bonjour
          --device      virtual device name to feed (default: BlackHole)
          --always-on   keep streaming even when nothing is recording
          --no-set-default  don't make the virtual device the default input
        """)
        exit(2)
    }
}

// MARK: - Core Audio helpers

func getProperty<T>(_ obj: AudioObjectID, _ selector: AudioObjectPropertySelector,
                    scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> [T] {
    var addr = AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(obj, &addr, 0, nil, &size) == noErr, size > 0 else { return [] }
    let count = Int(size) / MemoryLayout<T>.stride
    let ptr = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<T>.alignment)
    defer { ptr.deallocate() }
    guard AudioObjectGetPropertyData(obj, &addr, 0, nil, &size, ptr) == noErr else { return [] }
    let typed = ptr.bindMemory(to: T.self, capacity: count)
    return Array(UnsafeBufferPointer(start: typed, count: Int(size) / MemoryLayout<T>.stride))
}

func deviceName(_ id: AudioDeviceID) -> String {
    var addr = AudioObjectPropertyAddress(mSelector: kAudioObjectPropertyName,
                                          mScope: kAudioObjectPropertyScopeGlobal,
                                          mElement: kAudioObjectPropertyElementMain)
    var name: Unmanaged<CFString>?
    var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &name) == noErr, let n = name else { return "" }
    return n.takeRetainedValue() as String
}

func findDevice(matching: String) -> AudioDeviceID? {
    let ids: [AudioDeviceID] = getProperty(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDevices)
    return ids.first { deviceName($0).localizedCaseInsensitiveContains(matching) }
}

func setDefaultInput(_ id: AudioDeviceID) {
    var dev = id
    var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultInputDevice,
                                          mScope: kAudioObjectPropertyScopeGlobal,
                                          mElement: kAudioObjectPropertyElementMain)
    AudioObjectSetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil,
                               UInt32(MemoryLayout<AudioDeviceID>.size), &dev)
}

/// True when some process other than us is currently recording from `device`.
func someoneIsRecording(from device: AudioDeviceID) -> Bool {
    let me = getpid()
    let procs: [AudioObjectID] = getProperty(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyProcessObjectList)
    for p in procs {
        let pid: [pid_t] = getProperty(p, kAudioProcessPropertyPID)
        guard let pid = pid.first, pid != me else { continue }
        let running: [UInt32] = getProperty(p, kAudioProcessPropertyIsRunningInput)
        guard running.first ?? 0 != 0 else { continue }
        let devices: [AudioObjectID] = getProperty(p, kAudioProcessPropertyDevices, scope: kAudioObjectPropertyScopeInput)
        if devices.isEmpty || devices.contains(device) { return true }
    }
    return false
}

// MARK: - Jitter buffer

final class RingBuffer {
    private var buf: [Float]
    private var readIdx = 0, writeIdx = 0
    private(set) var count = 0
    private var lock = os_unfair_lock()
    private var primed = false
    let target: Int, maxFill: Int

    init(sampleRate: Double) {
        buf = [Float](repeating: 0, count: Int(sampleRate * 2))
        target = Int(sampleRate * 0.04)   // ~40 ms cushion before playback starts
        maxFill = Int(sampleRate * 0.2)   // drop old audio if latency builds past 200 ms
    }

    func write(_ samples: [Float]) {
        os_unfair_lock_lock(&lock); defer { os_unfair_lock_unlock(&lock) }
        for s in samples {
            buf[writeIdx] = s
            writeIdx = (writeIdx + 1) % buf.count
            if count == buf.count { readIdx = (readIdx + 1) % buf.count } else { count += 1 }
        }
        if count > maxFill {
            let skip = count - target
            readIdx = (readIdx + skip) % buf.count
            count -= skip
        }
    }

    func reset() {
        os_unfair_lock_lock(&lock); defer { os_unfair_lock_unlock(&lock) }
        readIdx = 0; writeIdx = 0; count = 0; primed = false
    }

    func read(into out: UnsafeMutablePointer<Float>, frames: Int) {
        os_unfair_lock_lock(&lock); defer { os_unfair_lock_unlock(&lock) }
        if !primed && count >= target { primed = true }
        var i = 0
        if primed {
            while i < frames && count > 0 {
                out[i] = buf[readIdx]
                readIdx = (readIdx + 1) % buf.count
                count -= 1
                i += 1
            }
            if count == 0 { primed = false }  // underrun: re-buffer before resuming
        }
        while i < frames { out[i] = 0; i += 1 }
    }
}

// MARK: - Receiver

final class Receiver {
    private let queue = DispatchQueue(label: "micbridge.receiver")
    private let device: AudioDeviceID
    private var browser: NWBrowser?
    private var senderEndpoint: NWEndpoint?
    private var conn: NWConnection?
    private var ready = false
    private var micRequested = false
    private var engine: AVAudioEngine?
    private var engineRate: Double = 0
    private var ring: RingBuffer?
    private var pending = Data()
    private var idleSince: Date?
    private var lastAttempt: Date?
    private var requestedAt: Date?

    init(device: AudioDeviceID) { self.device = device }

    func start() {
        if let host {
            senderEndpoint = .hostPort(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port)!)
        } else {
            let b = NWBrowser(for: .bonjour(type: serviceType, domain: nil), using: .tcp)
            b.browseResultsChangedHandler = { [weak self] results, _ in
                guard let self else { return }
                let ep = results.first?.endpoint
                if ep != self.senderEndpoint {
                    self.senderEndpoint = ep
                    log(ep.map { "found sender: \($0)" } ?? "sender went away")
                }
            }
            b.start(queue: queue)
            browser = b
        }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(250))
        timer.setEventHandler { [weak self] in self?.tick() }
        timer.resume()
        _timer = timer
    }
    private var _timer: DispatchSourceTimer?

    private func tick() {
        if conn == nil { connect() }
        let wanted = alwaysOn || someoneIsRecording(from: device)
        if wanted {
            idleSince = nil
            if ready && !micRequested {
                log("an app started recording — turning the MacBook mic on")
                command("S")
                micRequested = true
                requestedAt = Date()
            }
        } else if micRequested {
            // Short grace period so brief pauses between recordings don't bounce the mic.
            if idleSince == nil { idleSince = Date() }
            if Date().timeIntervalSince(idleSince!) > 3 {
                log("no app is recording any more — turning the MacBook mic off")
                command("P")
                micRequested = false
                idleSince = nil
            }
        }
    }

    private func command(_ c: String) {
        conn?.send(content: Data(c.utf8), completion: .idempotent)
    }

    // The connection stays up all the time so a recording only has to wait for the
    // Air's microphone to switch on, not for discovery, TCP setup and audio engine start.
    private func connect() {
        guard let ep = senderEndpoint else { return }
        if let t = lastAttempt, Date().timeIntervalSince(t) < 2 { return }
        lastAttempt = Date()
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        tcp.enableKeepalive = true
        tcp.keepaliveIdle = 10
        tcp.keepaliveInterval = 5
        tcp.keepaliveCount = 2
        let c = NWConnection(to: ep, using: NWParameters(tls: nil, tcp: tcp))
        conn = c
        c.stateUpdateHandler = { [weak self] state in
            guard let self, self.conn === c else { return }
            switch state {
            case .ready:
                log("connected to \(ep)")
                self.ready = true
                self.pending = Data()
                self.ensurePlayback(sampleRate: 48000)  // warm up; rebuilt if the Air uses another rate
                self.receive(c)
            case .failed(let e), .waiting(let e):
                log("connection problem: \(e)")
                self.disconnect()
            default: break
            }
        }
        c.start(queue: queue)
    }

    private func disconnect() {
        conn?.cancel()
        conn = nil
        ready = false
        micRequested = false
        idleSince = nil
        engine?.stop()
        engine = nil
        engineRate = 0
        ring = nil
        log("disconnected from sender")
    }

    private func receive(_ c: NWConnection) {
        c.receive(minimumIncompleteLength: 1, maximumLength: 16384) { [weak self] data, _, done, err in
            guard let self, self.conn === c else { return }
            if let data { self.handle(data) }
            if done || err != nil { log("sender closed the connection"); self.disconnect(); return }
            self.receive(c)
        }
    }

    private func handle(_ data: Data) {
        pending.append(data)
        var samples: [Float] = []
        var consumed = 0
        var newRate: Double?
        pending.withUnsafeBytes { raw in
            while raw.count - consumed >= 5 {
                let type = raw[consumed]
                let value = UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: consumed + 1, as: UInt32.self))
                if type == UInt8(ascii: "H") {
                    newRate = Double(value)
                    samples.removeAll()
                    consumed += 5
                } else if type == UInt8(ascii: "A") {
                    let len = Int(value)
                    guard raw.count - consumed >= 5 + len else { break }
                    for i in 0..<len / 2 {
                        let s = raw.loadUnaligned(fromByteOffset: consumed + 5 + i * 2, as: Int16.self)
                        samples.append(Float(Int16(littleEndian: s)) / 32768)
                    }
                    consumed += 5 + len
                } else {
                    consumed = -1
                    break
                }
            }
        }
        guard consumed >= 0 else { log("bad data from sender — is the Air running an older MicBridge?"); disconnect(); return }
        pending.removeFirst(consumed)
        if let newRate {
            ensurePlayback(sampleRate: newRate)
            ring?.reset()
            if let t = requestedAt {
                log(String(format: "MacBook mic is on (%.2f s after the request)", Date().timeIntervalSince(t)))
                requestedAt = nil
            }
        }
        if !samples.isEmpty { ring?.write(samples) }
    }

    private func ensurePlayback(sampleRate: Double) {
        if engine != nil && engineRate == sampleRate { return }
        engine?.stop()
        let ring = RingBuffer(sampleRate: sampleRate)
        self.ring = ring
        let engine = AVAudioEngine()
        var dev = device
        AudioUnitSetProperty(engine.outputNode.audioUnit!, kAudioOutputUnitProperty_CurrentDevice,
                             kAudioUnitScope_Global, 0, &dev, UInt32(MemoryLayout<AudioDeviceID>.size))
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!
        let source = AVAudioSourceNode(format: format) { _, _, frames, abl -> OSStatus in
            let buffers = UnsafeMutableAudioBufferListPointer(abl)
            for b in buffers {
                ring.read(into: b.mData!.assumingMemoryBound(to: Float.self), frames: Int(frames))
            }
            return noErr
        }
        engine.attach(source)
        engine.connect(source, to: engine.mainMixerNode, format: format)
        do {
            try engine.start()
            self.engine = engine
            engineRate = sampleRate
            log("audio output ready → \(deviceName(device)) (\(Int(sampleRate)) Hz)")
        } catch {
            log("could not start audio output: \(error)")
            self.engine = nil
            engineRate = 0
        }
    }
}

guard let device = findDevice(matching: deviceMatch) else {
    log("no audio device matching \"\(deviceMatch)\" — install BlackHole first: brew install blackhole-2ch")
    exit(1)
}
log("using virtual device: \(deviceName(device))")
if setDefault {
    setDefaultInput(device)
    log("set \(deviceName(device)) as the default input device")
}

let receiver = Receiver(device: device)
receiver.start()
log(alwaysOn ? "always-on mode" : "the MacBook mic turns on when an app records from \(deviceName(device))")
dispatchMain()
