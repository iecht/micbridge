// MicBridge Sender — runs on the MacBook Air.
// Advertises itself on the LAN via Bonjour. Receivers stay connected all the time
// and send a one-byte command when they need audio: "S" turns the microphone on,
// "P" turns it off. The microphone is on while at least one receiver wants it.
//
// Wire format, sender → receiver, as framed messages:
//   "H" + UInt32 LE sample rate          sent each time the mic starts
//   "A" + UInt32 LE byte count + Int16 LE mono samples

import AVFoundation
import Foundation
import Network

setvbuf(stdout, nil, _IOLBF, 0)

func log(_ msg: String) {
    let f = DateFormatter()
    f.dateFormat = "HH:mm:ss"
    print("[\(f.string(from: Date()))] \(msg)")
}

let serviceType = "_micbridge._tcp"
var port: UInt16 = 50555
var args = CommandLine.arguments.dropFirst().makeIterator()
while let a = args.next() {
    switch a {
    case "--port": port = UInt16(args.next() ?? "") ?? port
    default:
        print("usage: micbridge-sender [--port N]")
        exit(2)
    }
}

func tcpParameters() -> NWParameters {
    let tcp = NWProtocolTCP.Options()
    tcp.noDelay = true
    // Notice a receiver that vanished (sleep, Wi-Fi drop) within ~20 s.
    tcp.enableKeepalive = true
    tcp.keepaliveIdle = 10
    tcp.keepaliveInterval = 5
    tcp.keepaliveCount = 2
    return NWParameters(tls: nil, tcp: tcp)
}

final class Sender {
    private let queue = DispatchQueue(label: "micbridge.sender")
    private var engine: AVAudioEngine?
    private var clients: [ObjectIdentifier: NWConnection] = [:]
    private var active: Set<ObjectIdentifier> = []
    private var activity: NSObjectProtocol?
    private var listener: NWListener!

    func start() throws {
        listener = try NWListener(using: tcpParameters(), on: NWEndpoint.Port(rawValue: port)!)
        listener.service = NWListener.Service(name: Host.current().localizedName ?? "MacBook", type: serviceType)
        listener.stateUpdateHandler = { state in
            switch state {
            case .ready: log("listening on port \(port), advertised as \(serviceType)")
            case .failed(let e): log("listener failed: \(e)"); exit(1)
            default: break
            }
        }
        listener.newConnectionHandler = { [weak self] conn in self?.accept(conn) }
        listener.start(queue: queue)
    }

    private func accept(_ conn: NWConnection) {
        let id = ObjectIdentifier(conn)
        conn.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                log("receiver connected: \(conn.endpoint)")
                self.clients[id] = conn
                self.readCommands(conn)
            case .failed, .cancelled:
                self.drop(conn)
            default: break
            }
        }
        conn.start(queue: queue)
    }

    private func readCommands(_ conn: NWConnection) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 64) { [weak self] data, _, done, err in
            guard let self else { return }
            for byte in data ?? Data() {
                switch byte {
                case UInt8(ascii: "S"): self.setActive(conn, true)
                case UInt8(ascii: "P"): self.setActive(conn, false)
                default: break
                }
            }
            if done || err != nil { conn.cancel(); self.drop(conn) } else { self.readCommands(conn) }
        }
    }

    private func setActive(_ conn: NWConnection, _ on: Bool) {
        let id = ObjectIdentifier(conn)
        let wasOn = !active.isEmpty
        if on { active.insert(id) } else { active.remove(id) }
        if on {
            if !wasOn { startMic() }
            if let engine { send(header(rate: engine.inputNode.outputFormat(forBus: 0).sampleRate), to: conn) }
        } else if wasOn && active.isEmpty {
            stopMic()
        }
    }

    private func drop(_ conn: NWConnection) {
        let id = ObjectIdentifier(conn)
        guard clients.removeValue(forKey: id) != nil else { return }
        log("receiver disconnected")
        if active.remove(id) != nil && active.isEmpty { stopMic() }
    }

    private func header(rate: Double) -> Data {
        var d = Data("H".utf8)
        withUnsafeBytes(of: UInt32(rate).littleEndian) { d.append(contentsOf: $0) }
        return d
    }

    private func send(_ data: Data, to conn: NWConnection) {
        conn.send(content: data, completion: .idempotent)
    }

    private func startMic() {
        let engine = AVAudioEngine()
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0 else { log("no microphone available"); return }

        let sink = AVAudioSinkNode { [weak self] _, frames, abl -> OSStatus in
            guard let self else { return noErr }
            let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: abl))
            guard let ch0 = buffers.first?.mData?.assumingMemoryBound(to: Float.self) else { return noErr }
            let n = Int(frames)
            var data = Data(count: 5 + n * 2)
            data.withUnsafeMutableBytes { raw in
                raw[0] = UInt8(ascii: "A")
                raw.storeBytes(of: UInt32(n * 2).littleEndian, toByteOffset: 1, as: UInt32.self)
                for i in 0..<n {
                    let s = max(-1, min(1, ch0[i]))
                    raw.storeBytes(of: Int16(s * 32767).littleEndian, toByteOffset: 5 + i * 2, as: Int16.self)
                }
            }
            self.queue.async {
                for id in self.active { if let c = self.clients[id] { self.send(data, to: c) } }
            }
            return noErr
        }
        engine.attach(sink)
        engine.connect(input, to: sink, format: format)
        do {
            try engine.start()
            self.engine = engine
            activity = ProcessInfo.processInfo.beginActivity(
                options: [.userInitiated, .idleSystemSleepDisabled, .latencyCritical],
                reason: "Streaming microphone to Mac mini")
            log("microphone ON (\(Int(format.sampleRate)) Hz)")
        } catch {
            log("failed to start microphone: \(error)")
        }
    }

    private func stopMic() {
        engine?.stop()
        engine = nil
        if let a = activity { ProcessInfo.processInfo.endActivity(a); activity = nil }
        log("microphone OFF")
    }
}

AVCaptureDevice.requestAccess(for: .audio) { granted in
    if !granted {
        log("microphone permission denied — allow it in System Settings › Privacy & Security › Microphone")
    }
}

let sender = Sender()
do { try sender.start() } catch { log("cannot start: \(error)"); exit(1) }
dispatchMain()
