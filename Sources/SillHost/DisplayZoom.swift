import Foundation
import CoreGraphics

/// Larger text while streaming, applied: switches the streamed display to the mode
/// `DisplayZoomPolicy.pick` chooses and puts it back.
///
/// The change is made `.forAppOnly`: macOS keeps it only while this process runs, so a crash, a
/// `kill -9` or Quit puts every display back to its own mode by itself; `restore` does it sooner,
/// when nothing streams from the display any more. One display at a time: the one the stream shows.
/// The display's own mode is the one it had when Sill first touched it, kept until it is restored.
///
/// Windows on the display are moved and shrunk by macOS to fit the smaller desktop, as when the
/// resolution is changed by hand, and stay so when it is put back.
@MainActor
final class DisplayZoom {
    /// The display Sill switched, its own mode, the level it is at and the mode Sill set.
    private(set) var zoomed: (display: CGDirectDisplayID, original: CGDisplayMode, level: Int, set: CGDisplayMode)?

    /// The level the streamed display is at now (0: none switched).
    var level: Int { zoomed?.level ?? 0 }

    /// Puts `display` at `level` (any other display Sill switched goes back first). Returns whether
    /// a display's mode changed, so the caller can look at the display and its windows again.
    @discardableResult
    func apply(level: Int, to display: CGDirectDisplayID?) -> Bool {
        var changed = false
        if let z = zoomed, z.display != display || level == 0 { changed = restore() }
        guard let display, level > 0 else { return changed }
        if let z = zoomed, z.display == display, z.level == level { return changed }
        let original = zoomed?.original ?? CGDisplayCopyDisplayMode(display)
        guard let original else { return changed }
        let modes = Self.modes(of: display)
        guard let pick = DisplayZoomPolicy.pick(original: Self.describe(original), modes: modes.map(\.mode), level: level),
              let mode = modes.first(where: { $0.mode == pick })?.cg else {
            print("Larger text: \(Self.describe(original).describe) has no smaller mode of its shape; leaving it as it is.")
            if zoomed != nil { changed = restore() || changed }
            return changed
        }
        guard Self.set(mode, on: display) else {
            print("Larger text: could not switch display \(display) to \(pick.describe).")
            return changed
        }
        zoomed = (display, original, level, mode)
        print("Larger text (\(DisplayZoomPolicy.name(level: level))): display \(display) from \(Self.describe(original).describe) to \(pick.describe) while it streams.")
        return true
    }

    /// The switched display back to its own mode. Returns whether one was switched.
    @discardableResult
    func restore() -> Bool {
        guard let z = zoomed else { return false }
        zoomed = nil
        // A display unplugged meanwhile has nothing to put back.
        guard CGDisplayIsOnline(z.display) != 0 else { return true }
        if Self.set(z.original, on: z.display) {
            print("Larger text: display \(z.display) back to \(Self.describe(z.original).describe).")
        } else {
            print("Larger text: could not put display \(z.display) back to \(Self.describe(z.original).describe); it goes back when Sill quits.")
        }
        return true
    }

    private static func set(_ mode: CGDisplayMode, on display: CGDirectDisplayID) -> Bool {
        var config: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&config) == .success else { return false }
        guard CGConfigureDisplayWithDisplayMode(config, display, mode, nil) == .success else {
            CGCancelDisplayConfiguration(config)
            return false
        }
        return CGCompleteDisplayConfiguration(config, .forAppOnly) == .success
    }

    private static func modes(of display: CGDirectDisplayID) -> [(mode: DisplayZoomPolicy.Mode, cg: CGDisplayMode)] {
        let opts = [kCGDisplayShowDuplicateLowResolutionModes: kCFBooleanTrue] as CFDictionary
        let all = (CGDisplayCopyAllDisplayModes(display, opts) as? [CGDisplayMode]) ?? []
        return all.map { (describe($0), $0) }
    }

    private static func describe(_ m: CGDisplayMode) -> DisplayZoomPolicy.Mode {
        DisplayZoomPolicy.Mode(width: m.width, height: m.height, pixelWidth: m.pixelWidth, pixelHeight: m.pixelHeight,
                               refresh: m.refreshRate, usable: m.isUsableForDesktopGUI())
    }
}
