import Foundation
import CoreGraphics

/// Larger text while streaming (Viewport.largerText, HostConfig.largerText), the rule: which of a
/// display's modes to switch it to so everything on it is drawn larger in the picture a device gets.
///
/// Why: a device sees the display's points, not its pixels. A 27-inch at 2560×1440 points is
/// shrunk about three times onto an iPhone's 850-point-wide panel, a 13-inch MacBook Air's 1470
/// points about 1.7 times, so the same 13 pt text arrives at about 4 pt or 7.5 pt. A display set to
/// fewer points (System Settings › Displays' Larger Text) draws everything larger in the same
/// picture, its shape unchanged, so nothing is stretched.
///
/// Pure (CoreGraphics' geometry types only), so `Tests/checks/display-zoom` compiles it alone.
/// `DisplayZoom` (the coordinator's) reads the modes and applies the pick.
package enum DisplayZoomPolicy {
    /// One of a display's modes, as `CGDisplayCopyAllDisplayModes` lists it: points, backing
    /// pixels, refresh rate, and whether macOS offers it for the desktop.
    package struct Mode: Equatable, Sendable {
        package var width: Int
        package var height: Int
        package var pixelWidth: Int
        package var pixelHeight: Int
        package var refresh: Double
        package var usable: Bool

        package init(width: Int, height: Int, pixelWidth: Int, pixelHeight: Int, refresh: Double, usable: Bool = true) {
            self.width = width; self.height = height
            self.pixelWidth = pixelWidth; self.pixelHeight = pixelHeight
            self.refresh = refresh; self.usable = usable
        }

        /// Drawn at twice its points or more (Retina, "HiDPI").
        package var hiDPI: Bool { pixelWidth >= width * 2 - 1 }
        /// "1920×1080 pt (3840×2160 px)".
        package var describe: String { "\(width)×\(height) pt (\(pixelWidth)×\(pixelHeight) px)" }
    }

    /// The levels a device or the host's setting can ask for.
    package static let levels = 0...2

    /// The share of the display's points each level aims at: 1 none, 0.8 a bit larger, 0.65 larger.
    package static func factor(level: Int) -> Double {
        switch level {
        case 1: return 0.8
        case 2: return 0.65
        default: return 1
        }
    }

    /// "off", "a bit larger", "larger": for the log and the settings.
    package static func name(level: Int) -> String {
        switch level {
        case 1: return "a bit larger"
        case 2: return "larger"
        default: return "off"
        }
    }

    /// "Off", "A bit larger", "Larger": a picker's titles.
    package static func title(level: Int) -> String {
        let n = name(level: level)
        return n.prefix(1).uppercased() + n.dropFirst()
    }

    /// A level within `levels`; anything else is off.
    package static func clamped(_ level: Int?) -> Int {
        guard let level, levels.contains(level) else { return 0 }
        return level
    }

    /// The narrowest display a pick leaves: below this the Mac's own windows stop fitting.
    package static let minimumWidth = 960

    /// The mode to switch to from `original` (the display's own mode, before Sill touched it) at
    /// `level`, or nil to leave the display as it is (level 0, or nothing among `modes` is narrower
    /// than `original` at its shape). The candidates: usable for the desktop, `original`'s shape
    /// (within 2 %), narrower than it and at least `minimumWidth` (or `original`'s own width, if
    /// that is narrower still). The one whose width is nearest `original.width × factor` wins; among
    /// equally near ones, Retina when `original` is Retina, then the most pixels (the sharpest), then
    /// `original`'s refresh rate, then the higher one.
    package static func pick(original: Mode, modes: [Mode], level: Int) -> Mode? {
        let f = factor(level: clamped(level))
        guard f < 1, original.width > 0, original.height > 0 else { return nil }
        let shape = Double(original.width) / Double(original.height)
        let floor = min(minimumWidth, original.width)
        let target = Double(original.width) * f
        let candidates = modes.filter { m in
            m.usable && m.width > 0 && m.height > 0 && m.width < original.width && m.width >= floor
                && abs(Double(m.width) / Double(m.height) - shape) / shape <= 0.02
        }
        func better(_ a: Mode, _ b: Mode) -> Bool {
            let da = abs(Double(a.width) - target), db = abs(Double(b.width) - target)
            if da != db { return da < db }
            if original.hiDPI, a.hiDPI != b.hiDPI { return a.hiDPI }
            if a.pixelWidth != b.pixelWidth { return a.pixelWidth > b.pixelWidth }
            let ra = abs(a.refresh - original.refresh), rb = abs(b.refresh - original.refresh)
            if ra != rb { return ra < rb }
            return a.refresh > b.refresh
        }
        return candidates.min { better($0, $1) }
    }

    /// The level the stream wants: the largest any connected device asks for, a device that has not
    /// said (nil: Sill's own app, an older Sill Legacy) taking the host's setting. Off with nobody.
    package static func wanted(devices: [Int?], host: Int) -> Int {
        devices.map { clamped($0 ?? host) }.max() ?? 0
    }
}
