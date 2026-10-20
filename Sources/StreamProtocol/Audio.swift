import Foundation

/// About 20 ms of the Mac's sound (kind 33): the sample rate (UInt32 BE), the channel count (UInt8),
/// then interleaved signed 16-bit little-endian samples. Plain PCM, 1.5 Mbit/s at 48 kHz stereo,
/// which a home network carries beside the video and any device plays without a decoder. The
/// layout is the Mac client's plain kind 33 (the mac-viewer-linux branch), so the two stay one.
public enum AudioPacket {
    public static func pack(sampleRate: UInt32, channels: UInt8, samples: UnsafeBufferPointer<Int16>) -> Data {
        var d = Data(capacity: 5 + samples.count * 2)
        d.appendBigEndian(sampleRate)
        d.append(channels)
        samples.withMemoryRebound(to: UInt8.self) { d.append(contentsOf: $0) }   // Apple silicon and Intel are little-endian
        return d
    }

    /// The rate, channels and samples of a kind 33; nil when malformed.
    public static func unpack(_ d: Data) -> (sampleRate: Double, channels: Int, samples: [Int16])? {
        guard d.count >= 5 else { return nil }
        let rate = d.readBigEndian(UInt32.self, at: 0)
        let channels = Int(d[d.startIndex + 4])
        guard rate >= 8_000, rate <= 192_000, (1...8).contains(channels), (d.count - 5) % (2 * channels) == 0 else { return nil }
        var samples = [Int16](repeating: 0, count: (d.count - 5) / 2)
        _ = samples.withUnsafeMutableBytes { dst in
            d.copyBytes(to: dst, from: (d.startIndex + 5)..<d.endIndex)
        }
        return (Double(rate), channels, samples)
    }
}
