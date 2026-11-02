import Foundation
import CoreGraphics

// Checks DisplayZoomPolicy (Sources/SillHost/DisplayZoomPolicy.swift): which mode a streamed display
// switches to for larger text, and the level the devices want.
//
// Compiled alone with this file (run.sh): swiftc -O -package-name sill DisplayZoomPolicy.swift main.swift

var failures = 0
var passes = 0
func check(_ ok: Bool, _ what: @autoclosure () -> String) {
    if ok { passes += 1 } else { failures += 1; print("FAIL: \(what())") }
}
func eq<T: Equatable>(_ got: T, _ want: T, _ what: String) { check(got == want, "\(what): got \(got), want \(want)") }

typealias Mode = DisplayZoomPolicy.Mode
func M(_ w: Int, _ h: Int, _ s: Int = 1, hz: Double = 60, usable: Bool = true) -> Mode {
    Mode(width: w, height: h, pixelWidth: w * s, pixelHeight: h * s, refresh: hz, usable: usable)
}
func picked(_ original: Mode, _ modes: [Mode], _ level: Int) -> String {
    DisplayZoomPolicy.pick(original: original, modes: modes, level: level).map { "\($0.width)×\($0.height)@\($0.pixelWidth / max($0.width, 1))x" } ?? "none"
}

// MARK: Levels

eq(DisplayZoomPolicy.factor(level: 0), 1, "level 0: no change")
eq(DisplayZoomPolicy.factor(level: 1), 0.8, "level 1: 80 %")
eq(DisplayZoomPolicy.factor(level: 2), 0.65, "level 2: 65 %")
eq(DisplayZoomPolicy.clamped(nil), 0, "clamped: nil is off")
eq(DisplayZoomPolicy.clamped(-1), 0, "clamped: below is off")
eq(DisplayZoomPolicy.clamped(3), 0, "clamped: above is off")
eq(DisplayZoomPolicy.clamped(2), 2, "clamped: a level stays")
eq(DisplayZoomPolicy.name(level: 1), "a bit larger", "name 1")
eq(DisplayZoomPolicy.title(level: 0), "Off", "title 0")
eq(DisplayZoomPolicy.title(level: 2), "Larger", "title 2")

// MARK: wanted

eq(DisplayZoomPolicy.wanted(devices: [], host: 2), 0, "wanted: nobody, nothing")
eq(DisplayZoomPolicy.wanted(devices: [nil], host: 2), 2, "wanted: Sill's own app takes the host's")
eq(DisplayZoomPolicy.wanted(devices: [0], host: 2), 0, "wanted: a device that says off is off")
eq(DisplayZoomPolicy.wanted(devices: [1, nil], host: 0), 1, "wanted: the largest any device asks for")
eq(DisplayZoomPolicy.wanted(devices: [1, nil], host: 2), 2, "wanted: the host's for a device that does not say, if larger")
eq(DisplayZoomPolicy.wanted(devices: [9], host: 0), 0, "wanted: an unknown level is off")

// MARK: pick: a 27-inch at 2560×1440 (non-Retina), as macOS lists it with the low-resolution duplicates

let qhd = M(2560, 1440)
let qhdModes = [qhd, M(2048, 1152), M(1920, 1080), M(1600, 900), M(1280, 720), M(1280, 720, 2), M(1024, 768), M(800, 600), M(1280, 1024)]
eq(picked(qhd, qhdModes, 0), "none", "27-inch, off: left alone")
eq(picked(qhd, qhdModes, 1), "2048×1152@1x", "27-inch, a bit larger: 2048 (target 2048)")
eq(picked(qhd, qhdModes, 2), "1600×900@1x", "27-inch, larger: 1600 (target 1664)")
eq(picked(qhd, qhdModes.filter { $0.width != 2048 }, 1), "1920×1080@1x", "27-inch without 2048: 1920 is nearest")

// A 27-inch 5K (Retina): its modes all HiDPI and some not.
let fiveK = M(2560, 1440, 2)
let fiveKModes = [fiveK, M(2560, 1440), M(2304, 1296, 2), M(2048, 1152, 2), M(2048, 1152), M(1920, 1080, 2), M(1600, 900, 2), M(1280, 720, 2)]
eq(picked(fiveK, fiveKModes, 1), "2048×1152@2x", "5K, a bit larger: the Retina 2048, not the 1x one")
eq(picked(fiveK, fiveKModes, 2), "1600×900@2x", "5K, larger: 1600 Retina")

// A 13-inch MacBook Air (2560×1664 px, 16:10-ish 1470×956 default).
let air = M(1470, 956, 2)
let airModes = [M(1710, 1112, 2), air, M(1280, 832, 2), M(1024, 665, 2), M(1470, 956), M(1280, 832)]
eq(picked(air, airModes, 1), "1280×832@2x", "Air, a bit larger: 1280 (target 1176)")
eq(picked(air, airModes, 2), "1024×665@2x", "Air, larger: 1024 (target 955.5)")

// The floor: nothing narrower than 960 unless the display already is.
let small = M(1280, 800, 2)
eq(picked(small, [small, M(1024, 640, 2), M(800, 500, 2)], 2), "1024×640@2x", "the floor keeps 1024 over 800 (target 832)")
eq(picked(small, [small, M(800, 500, 2)], 2), "none", "only modes under the floor: left alone")
let tiny = M(900, 600)
eq(picked(tiny, [tiny, M(720, 480)], 1), "none", "a display already under the floor stays as it is")

// Shape: another aspect never, so nothing is stretched.
eq(picked(qhd, [qhd, M(1280, 1024), M(1024, 768), M(1600, 1200)], 1), "none", "no mode of its shape: left alone")
eq(picked(M(3440, 1440), [M(3440, 1440), M(2560, 1080), M(1920, 1080)], 1), "2560×1080@1x", "an ultrawide keeps 21:9")

// Never wider, never the same, never one macOS keeps from the desktop.
eq(picked(air, [air, M(1710, 1112, 2)], 1), "none", "only wider: left alone")
eq(picked(qhd, [qhd, M(2048, 1152, usable: false), M(1920, 1080)], 1), "1920×1080@1x", "a mode not usable for the desktop is skipped")

// Refresh: the original's rate among equals, then the higher.
let pro = M(1512, 982, 2)
let proPick = DisplayZoomPolicy.pick(original: Mode(width: 1512, height: 982, pixelWidth: 3024, pixelHeight: 1964, refresh: 120),
                                     modes: [M(1352, 878, 2, hz: 60), M(1352, 878, 2, hz: 120), M(1352, 878, 2, hz: 48)], level: 1)
eq(proPick?.refresh, 120, "refresh: the original's 120")
let anyPick = DisplayZoomPolicy.pick(original: pro, modes: [M(1352, 878, 2, hz: 48), M(1352, 878, 2, hz: 50)], level: 1)
eq(anyPick?.refresh, 50, "refresh: without the original's, the nearer")

// Degenerate input never traps.
eq(picked(M(0, 0), qhdModes, 1), "none", "a display with no size: left alone")
eq(picked(qhd, [], 2), "none", "no modes: left alone")
eq(picked(qhd, [M(0, 0)], 2), "none", "a mode with no size is skipped")

// Every level on random displays: the pick is narrower, at the shape, usable, and nothing nearer.
var rng = SystemRandomNumberGenerator()
for _ in 0..<5000 {
    let w = Int.random(in: 600...6000, using: &rng), h = Int.random(in: 400...3000, using: &rng)
    let original = M(w, h, Bool.random(using: &rng) ? 2 : 1)
    var modes: [Mode] = [original]
    for _ in 0..<Int.random(in: 0...12, using: &rng) {
        let f = Double.random(in: 0.3...1.2, using: &rng)
        let sameShape = Bool.random(using: &rng)
        let mw = max(1, Int(Double(w) * f)), mh = sameShape ? max(1, Int((Double(mw) * Double(h) / Double(w)).rounded())) : Int.random(in: 300...3000, using: &rng)
        modes.append(M(mw, mh, Bool.random(using: &rng) ? 2 : 1, usable: Int.random(in: 0...9, using: &rng) > 0))
    }
    for level in 0...2 {
        guard let p = DisplayZoomPolicy.pick(original: original, modes: modes, level: level) else { continue }
        check(level > 0, "random: level 0 never picks")
        check(p.width < original.width && p.usable, "random: narrower and usable (\(p.describe) from \(original.describe))")
        check(p.width >= min(DisplayZoomPolicy.minimumWidth, original.width), "random: never under the floor")
        let shape = Double(w) / Double(h)
        check(abs(Double(p.width) / Double(p.height) - shape) / shape <= 0.02, "random: the display's shape")
        let target = Double(w) * DisplayZoomPolicy.factor(level: level)
        let nearer = modes.contains { m in
            m.usable && m.width < w && m.width >= min(DisplayZoomPolicy.minimumWidth, w) && m.height > 0
                && abs(Double(m.width) / Double(m.height) - shape) / shape <= 0.02
                && abs(Double(m.width) - target) < abs(Double(p.width) - target)
        }
        check(!nearer, "random: nothing nearer the target than \(p.describe)")
    }
}

print("display-zoom: \(passes) checks passed, \(failures) failed")
exit(failures == 0 ? 0 : 1)
