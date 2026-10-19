import AVFoundation
import Combine
import StreamProtocol

/// This Mac's microphone to the other computer (kind 43), which offers it to its apps as a
/// microphone of its own ("Sill Microphone" on Sill for Linux): 10 ms packets of 48 kHz mono 16-bit
/// PCM (AudioPacket's plain layout, about 770 kbit/s). Runs while Send Microphone is on, a session is
/// connected and its host says `microphone`; macOS asks for the microphone the first time.
/// The engine is the main thread's; conversion and sending run on a queue of their own.
final class MicrophoneSender {
    static let defaultsKey = "SillClient.sendMic"
    static var enabled: Bool {
        get { UserDefaults.standard.bool(forKey: defaultsKey) }
        set { UserDefaults.standard.set(newValue, forKey: defaultsKey) }
    }

    static let rate = 48_000.0
    private static let packetFrames = 480      // 10 ms

    private let client: StreamClient
    private var engine: AVAudioEngine?
    private var subscriptions = Set<AnyCancellable>()
    private let queue = DispatchQueue(label: "sill.microphone")
    private let outFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: MicrophoneSender.rate, channels: 1, interleaved: true)!
    private var converter: AVAudioConverter?   // on `queue`
    private var pending = Data()               // on `queue`
    private(set) var denied = false

    init(client: StreamClient) {
        self.client = client
        client.$connected.removeDuplicates().sink { [weak self] _ in DispatchQueue.main.async { self?.update() } }.store(in: &subscriptions)
        client.$hostMicrophone.removeDuplicates().sink { [weak self] _ in DispatchQueue.main.async { self?.update() } }.store(in: &subscriptions)
    }

    /// Starts or stops as the switch, the session and its host say. Main thread.
    func update() {
        if Self.enabled && client.connected && client.hostMicrophone { start() } else { stop() }
    }

    private func start() {
        guard engine == nil else { return }
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] _ in DispatchQueue.main.async { self?.update() } }
            return
        case .denied, .restricted:
            if !denied { print("microphone: access denied; allow Sill Viewer in System Settings › Privacy & Security › Microphone") }
            denied = true
            return
        default:
            denied = false
        }
        let engine = AVAudioEngine()
        let input = engine.inputNode
        let inFormat = input.outputFormat(forBus: 0)
        guard inFormat.sampleRate > 0, inFormat.channelCount > 0,
              let converter = AVAudioConverter(from: inFormat, to: outFormat) else {
            print("microphone: no input device")
            return
        }
        queue.sync { self.converter = converter; self.pending = Data() }
        input.installTap(onBus: 0, bufferSize: 1024, format: inFormat) { [weak self] buffer, _ in
            guard let self, let copy = Self.copy(buffer) else { return }
            self.queue.async { self.convertAndSend(copy) }
        }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            print("microphone: could not start (\(error.localizedDescription))")
            return
        }
        self.engine = engine
        print("microphone: sending to \(client.macName) (\(Int(inFormat.sampleRate)) Hz in)")
    }

    func stop() {
        guard let engine else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        self.engine = nil
        queue.async { self.converter = nil; self.pending = Data() }
        print("microphone: stopped")
    }

    /// The tap's buffer is reused by the engine: a copy goes to the queue.
    private static func copy(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let copy = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: buffer.frameLength) else { return nil }
        copy.frameLength = buffer.frameLength
        let channels = Int(buffer.format.channelCount), frames = Int(buffer.frameLength)
        if let src = buffer.floatChannelData, let dst = copy.floatChannelData {
            for c in 0..<(buffer.format.isInterleaved ? 1 : channels) {
                dst[c].update(from: src[c], count: frames * (buffer.format.isInterleaved ? channels : 1))
            }
        } else if let src = buffer.int16ChannelData, let dst = copy.int16ChannelData {
            for c in 0..<(buffer.format.isInterleaved ? 1 : channels) {
                dst[c].update(from: src[c], count: frames * (buffer.format.isInterleaved ? channels : 1))
            }
        } else {
            return nil
        }
        return copy
    }

    /// On `queue`: to 48 kHz mono 16-bit, then out in 10 ms packets.
    private func convertAndSend(_ buffer: AVAudioPCMBuffer) {
        guard let converter else { return }
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * Self.rate / buffer.format.sampleRate) + 32
        guard let out = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: capacity) else { return }
        var given = false
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if given { status.pointee = .noDataNow; return nil }
            given = true
            status.pointee = .haveData
            return buffer
        }
        guard error == nil, out.frameLength > 0, let samples = out.int16ChannelData else { return }
        pending.append(Data(bytes: samples[0], count: Int(out.frameLength) * 2))
        let packetBytes = Self.packetFrames * 2
        // Never more than 100 ms behind: a stall is dropped, not sent late.
        if pending.count > packetBytes * 10 { pending.removeFirst(pending.count - packetBytes * 2) }
        while pending.count >= packetBytes {
            var payload = Data(capacity: 5 + packetBytes)
            withUnsafeBytes(of: UInt32(Self.rate).bigEndian) { payload.append(contentsOf: $0) }
            payload.append(1)
            payload.append(pending.prefix(packetBytes))
            pending.removeFirst(packetBytes)
            client.send(.microphone, payload: payload)
        }
    }
}
