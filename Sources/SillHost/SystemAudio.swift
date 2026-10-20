import AudioToolbox
import CoreAudio
import Foundation
import StreamProtocol

/// Everything this Mac plays (kind 33, Viewport.audio), for the devices that asked: one CoreAudio
/// process tap over every process but this one, muted on this Mac while it is tapped
/// (`mutedWhenTapped`: the sound goes to the device instead, and comes back here when the tap
/// stops). The tap is read through a private aggregate device; each ~20 ms of it goes out as
/// 16-bit PCM (AudioPacket). The first tap asks for the audio recording permission, which for the
/// CLI belongs to Terminal (System Settings › Privacy & Security › Screen & System Audio Recording,
/// "System Audio Recording Only"); without it the tap reads silence, which the host says once.
/// CoreAudio's calls wait on coreaudiod, so they run on a queue of their own; `set` returns at once.
@available(macOS 14.2, *)
final class SystemAudio: @unchecked Sendable {
    /// About 20 ms of sound, packed (AudioPacket), on the IO queue.
    var onPacket: ((Data) -> Void)?

    private var running = false
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private let ioQueue = DispatchQueue(label: "sill.audio", qos: .userInteractive)
    private let control = DispatchQueue(label: "sill.audio.control", qos: .userInitiated)

    /// Tap while some device listens; stop when none does. Any thread; returns at once.
    func set(running wanted: Bool) {
        control.async { [self] in
            guard wanted != running else { return }
            running = wanted
            if wanted {
                do {
                    try start()
                    print("Audio: this Mac's sound is muted here and sent to the device.")
                } catch {
                    print("Audio: could not tap this Mac's sound (\(error)); it stays on this Mac.")
                    teardown()
                }
            } else {
                teardown()
                print("Audio: the device stopped listening; this Mac's sound is back here.")
            }
        }
    }

    /// The tap gone and the sound back on this Mac before returning (the host quitting): at most a
    /// second, so a stuck coreaudiod never holds the quit. A private tap also goes with its process.
    func stop() {
        let done = DispatchSemaphore(value: 0)
        control.async { [self] in
            running = false
            teardown()
            done.signal()
        }
        _ = done.wait(timeout: .now() + 1)
    }

    // MARK: CoreAudio

    struct Failure: Error, CustomStringConvertible {
        let step: String, status: OSStatus
        var description: String { "\(step): \(status)" }
    }

    private func start() throws {
        let desc = CATapDescription(stereoGlobalTapButExcludeProcesses: Self.ownProcess())
        desc.name = "Sill"
        desc.muteBehavior = .mutedWhenTapped
        desc.isPrivate = true
        var tap = AudioObjectID(kAudioObjectUnknown)
        var err = AudioHardwareCreateProcessTap(desc, &tap)
        guard err == noErr else { throw Failure(step: "create tap", status: err) }
        tapID = tap

        let output = try Self.defaultOutputUID()
        let aggregate: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Sill",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: output,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: output]],
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapDriftCompensationKey: true, kAudioSubTapUIDKey: desc.uuid.uuidString]],
        ]
        var agg = AudioObjectID(kAudioObjectUnknown)
        err = AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &agg)
        guard err == noErr else { throw Failure(step: "create aggregate device", status: err) }
        aggregateID = agg

        var format = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var address = AudioObjectPropertyAddress(mSelector: kAudioTapPropertyFormat, mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        err = AudioObjectGetPropertyData(tap, &address, 0, nil, &size, &format)
        guard err == noErr else { throw Failure(step: "read the tap's format", status: err) }
        guard format.mFormatID == kAudioFormatLinearPCM, format.mFormatFlags & kAudioFormatFlagIsFloat != 0, format.mBitsPerChannel == 32
        else { throw Failure(step: "the tap's format is not 32-bit float", status: -1) }

        let packer = Packer(sampleRate: format.mSampleRate, channels: Int(max(1, min(format.mChannelsPerFrame, 2))))
        let send = onPacket
        var proc: AudioDeviceIOProcID?
        err = AudioDeviceCreateIOProcIDWithBlock(&proc, agg, ioQueue) { _, input, _, _, _ in
            packer.add(UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input)), send: send)
        }
        guard err == noErr, let proc else { throw Failure(step: "create the IO proc", status: err) }
        procID = proc
        err = AudioDeviceStart(agg, proc)
        guard err == noErr else { throw Failure(step: "start", status: err) }
    }

    private func teardown() {
        if let procID {
            AudioDeviceStop(aggregateID, procID)
            AudioDeviceDestroyIOProcID(aggregateID, procID)
        }
        procID = nil
        if aggregateID != kAudioObjectUnknown { AudioHardwareDestroyAggregateDevice(aggregateID) }
        aggregateID = AudioObjectID(kAudioObjectUnknown)
        if tapID != kAudioObjectUnknown { AudioHardwareDestroyProcessTap(tapID) }
        tapID = AudioObjectID(kAudioObjectUnknown)
    }

    /// This process's audio object, so the tap never hears Sill itself.
    private static func ownProcess() -> [AudioObjectID] {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
                                                 mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var pid = getpid()
        var object = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let err = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address,
                                             UInt32(MemoryLayout<pid_t>.size), &pid, &size, &object)
        return err == noErr && object != kAudioObjectUnknown ? [object] : []
    }

    private static func defaultOutputUID() throws -> String {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultSystemOutputDevice,
                                                 mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var device = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var err = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device)
        guard err == noErr else { throw Failure(step: "the default output", status: err) }
        address.mSelector = kAudioDevicePropertyDeviceUID
        var uid: Unmanaged<CFString>?
        size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        err = AudioObjectGetPropertyData(device, &address, 0, nil, &size, &uid)
        guard err == noErr, let uid else { throw Failure(step: "the default output's UID", status: err) }
        return uid.takeRetainedValue() as String
    }
}

/// Float frames in, 16-bit packets of about 20 ms out. On the IO queue only. Says once when the
/// first 3 s were all exact zeros: what a tap without the recording permission reads.
private final class Packer: @unchecked Sendable {
    let sampleRate: Double
    let channels: Int
    private let framesPerPacket: Int
    private var pending: [Int16] = []
    private var silentFrames = 0
    private var judged = false

    init(sampleRate: Double, channels: Int) {
        self.sampleRate = sampleRate
        self.channels = channels
        framesPerPacket = max(1, Int(sampleRate / 50))
        pending.reserveCapacity(framesPerPacket * channels * 2)
    }

    func add(_ buffers: UnsafeMutableAudioBufferListPointer, send: ((Data) -> Void)?) {
        guard let send, let first = buffers.first, let data0 = first.mData else { return }
        var heard = false
        let frames: Int
        if buffers.count == 1 {
            // Interleaved: one buffer of every channel's samples.
            let have = Int(first.mNumberChannels)
            frames = Int(first.mDataByteSize) / (4 * max(1, have))
            let src = data0.assumingMemoryBound(to: Float.self)
            for f in 0..<frames {
                for c in 0..<channels {
                    let v = src[f * have + min(c, have - 1)]
                    if v != 0 { heard = true }
                    pending.append(Self.int16(v))
                }
            }
        } else {
            // One buffer a channel.
            frames = Int(first.mDataByteSize) / 4
            let srcs = (0..<channels).map { buffers[min($0, buffers.count - 1)].mData?.assumingMemoryBound(to: Float.self) }
            for f in 0..<frames {
                for c in 0..<channels {
                    let v = srcs[c]?[f] ?? 0
                    if v != 0 { heard = true }
                    pending.append(Self.int16(v))
                }
            }
        }
        if !judged {
            if heard {
                judged = true
            } else {
                silentFrames += frames
                if Double(silentFrames) >= sampleRate * 3 {
                    judged = true
                    print("Audio: 3 s of silence so far. If something is playing, allow \"System Audio Recording\" for the app that runs SillHost (System Settings › Privacy & Security › Screen & System Audio Recording), then run it again.")
                }
            }
        }
        let step = framesPerPacket * channels
        while pending.count >= step {
            let packet = pending.withUnsafeBufferPointer {
                AudioPacket.pack(sampleRate: UInt32(sampleRate), channels: UInt8(channels), samples: UnsafeBufferPointer(rebasing: $0[0..<step]))
            }
            pending.removeFirst(step)
            send(packet)
        }
    }

    private static func int16(_ v: Float) -> Int16 { Int16(max(-1, min(1, v)) * 32767) }
}
