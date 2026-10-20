import AudioToolbox
import CoreAudio
import Foundation

/// A device's microphone (kind 43) as a microphone of this Mac: macOS has no way for an app to add
/// an input device, so the sound is played into a loopback device's output, and the Mac's apps
/// (FaceTime, Zoom, Teams…) pick that device as their microphone. BlackHole is the free one
/// (`brew install blackhole-2ch`); `SILL_MIC_DEVICE=<name>` picks another by the start of its name.
///
/// An AudioQueue on that device, fed the packets as they come with a short cushion; a packet that
/// would put more than `ceiling` behind is dropped, so the voice stays close to live. Any thread:
/// everything runs on `queue`. This process is left out of SystemAudio's tap, so what plays here is
/// never muted or sent back to the device.
final class MicrophoneOut: @unchecked Sendable {
    private static let cushion = 0.06
    private static let ceiling = 0.25

    /// The loopback device's UID, looked for once; nil when there is none (the window list then
    /// says nothing of a microphone, and the device sends none).
    let deviceUID: String?
    var available: Bool { deviceUID != nil }

    private let queue = DispatchQueue(label: "sill.microphone", qos: .userInteractive)
    private var audioQueue: AudioQueueRef?
    private var format = AudioStreamBasicDescription()
    private var queued = 0.0            // seconds enqueued and not yet played, on `queue`
    private var running = false
    private var lastPacketAt = 0.0
    private var idleTimer: DispatchSourceTimer?

    init() {
        let wanted = ProcessInfo.processInfo.environment["SILL_MIC_DEVICE"] ?? "BlackHole"
        let found = Self.outputDevices().first { $0.name.lowercased().hasPrefix(wanted.lowercased()) }
        deviceUID = found?.uid
        if let found {
            print("Microphone: a device's microphone plays into \"\(found.name)\"; pick it as the microphone in the Mac's apps.")
        } else {
            print("Microphone: no \"\(wanted)\" device, so devices can't send their microphone. Install BlackHole (brew install blackhole-2ch) and run SillHost again.")
        }
    }

    /// One packet: interleaved 16-bit samples.
    func play(sampleRate: Double, channels: Int, samples: [Int16]) {
        guard let uid = deviceUID, !samples.isEmpty else { return }
        queue.async { [self] in
            if audioQueue == nil || format.mSampleRate != sampleRate || Int(format.mChannelsPerFrame) != channels {
                open(uid: uid, sampleRate: sampleRate, channels: channels)
            }
            guard let aq = audioQueue else { return }
            let seconds = Double(samples.count / channels) / sampleRate
            guard queued + seconds <= Self.ceiling else { return }
            let bytes = UInt32(samples.count * 2)
            var buffer: AudioQueueBufferRef?
            guard AudioQueueAllocateBuffer(aq, bytes, &buffer) == noErr, let buffer else { return }
            samples.withUnsafeBytes { buffer.pointee.mAudioData.copyMemory(from: $0.baseAddress!, byteCount: Int(bytes)) }
            buffer.pointee.mAudioDataByteSize = bytes
            guard AudioQueueEnqueueBuffer(aq, buffer, 0, nil) == noErr else { AudioQueueFreeBuffer(aq, buffer); return }
            queued += seconds
            lastPacketAt = CFAbsoluteTimeGetCurrent()
            if !running, queued >= Self.cushion {
                running = AudioQueueStart(aq, nil) == noErr
            }
        }
    }

    private func open(uid: String, sampleRate: Double, channels: Int) {
        close()
        format = AudioStreamBasicDescription(mSampleRate: sampleRate, mFormatID: kAudioFormatLinearPCM,
                                             mFormatFlags: kLinearPCMFormatFlagIsSignedInteger | kLinearPCMFormatFlagIsPacked,
                                             mBytesPerPacket: UInt32(2 * channels), mFramesPerPacket: 1,
                                             mBytesPerFrame: UInt32(2 * channels), mChannelsPerFrame: UInt32(channels),
                                             mBitsPerChannel: 16, mReserved: 0)
        var aq: AudioQueueRef?
        let status = AudioQueueNewOutputWithDispatchQueue(&aq, &format, 0, queue) { [weak self] aq, buffer in
            // On `queue`: a buffer played out. A queue already closed freed its own buffers.
            guard let self, aq == self.audioQueue else { return }
            self.queued = max(0, self.queued - Double(buffer.pointee.mAudioDataByteSize) / Double(self.format.mBytesPerFrame) / self.format.mSampleRate)
            AudioQueueFreeBuffer(aq, buffer)
            if self.queued < 0.001, self.running {
                // Dry: pause, and gather a cushion again before playing.
                AudioQueuePause(aq)
                self.running = false
            }
        }
        guard status == noErr, let aq else { print("Microphone: could not open an audio queue (\(status))."); return }
        var device = uid as CFString
        let set = AudioQueueSetProperty(aq, kAudioQueueProperty_CurrentDevice, &device, UInt32(MemoryLayout<CFString>.size))
        guard set == noErr else {
            print("Microphone: could not play into the loopback device (\(set)).")
            AudioQueueDispose(aq, true)
            return
        }
        audioQueue = aq
        queued = 0
        running = false
        print("Microphone: a device's microphone is playing (\(Int(sampleRate)) Hz).")
        // Closed after 5 s without a packet (the device stopped sending or left).
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 5, repeating: 5)
        t.setEventHandler { [weak self] in
            guard let self, CFAbsoluteTimeGetCurrent() - self.lastPacketAt > 5 else { return }
            self.close()
            print("Microphone: the device stopped sending.")
        }
        t.resume()
        idleTimer = t
    }

    private func close() {
        idleTimer?.cancel()
        idleTimer = nil
        if let aq = audioQueue { AudioQueueDispose(aq, true) }
        audioQueue = nil
        queued = 0
        running = false
    }

    /// Every device with outputs: its name and UID.
    private static func outputDevices() -> [(name: String, uid: String)] {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices, mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids) == noErr else { return [] }
        return ids.compactMap { id in
            var streams = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams, mScope: kAudioObjectPropertyScopeOutput,
                                                     mElement: kAudioObjectPropertyElementMain)
            var streamSize: UInt32 = 0
            guard AudioObjectGetPropertyDataSize(id, &streams, 0, nil, &streamSize) == noErr, streamSize > 0,
                  let name = string(id, kAudioObjectPropertyName), let uid = string(id, kAudioDevicePropertyDeviceUID) else { return nil }
            return (name, uid)
        }
    }

    private static func string(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr, let value else { return nil }
        return value.takeRetainedValue() as String
    }
}
