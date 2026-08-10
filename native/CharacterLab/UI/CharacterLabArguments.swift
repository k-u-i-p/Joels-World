import Foundation

/// **How the lab is asked for things from a script.**
///
/// The map editor already has `-shot`, and the lab needs the same idea in a different shape:
/// not one picture of a world, but a filmstrip of a movement, a texture sheet, or a table of
/// numbers. Everything below is a launch argument for the same reason `-shot` is one — a tool
/// that can only be driven by hand cannot be used to check anything twice.
///
/// ```bash
/// # Look at it
/// "Joels World Character Lab.app/Contents/MacOS/Joels World Character Lab"
///
/// # One picture of the walk cycle, side on, half way through
/// … -labtake walk -labtime 3 -labshot /tmp/walk.png
///
/// # Eight frames across the sprint, captioned, in one image
/// … -labtake run -labsheet /tmp/run.png -labframes 8
///
/// # One frame of every take, to see the whole rig at a glance
/// … -labtake all -labsheet /tmp/all.png
///
/// # The numbers: foot contact, hip bounce, lean, per take
/// … -labreport /tmp/lab.json
/// ```
///
/// The `lab` prefix is kept on every flag even though the app is now nothing but the lab: they
/// read the same in a script whichever binary grows them, and the map editor's own `-shot`
/// family sits next to them in a shell history.
enum CharacterLabArguments {

    /// `-labtake <id>`, or `all` for one frame of every take in a sheet.
    static var takeId: String? { value("-labtake") }
    static var wantsEveryTake: Bool { takeId == "all" }

    static var cast: CharacterLabCast.Kind {
        value("-labcast").flatMap(CharacterLabCast.Kind.init(rawValue:)) ?? .solo
    }

    static var view: CharacterLabView? {
        value("-labview").flatMap(CharacterLabView.init(rawValue:))
    }

    /// `-labtime <seconds>` — pin the clock. Implied paused.
    static var time: Double? { number("-labtime") }
    /// `-labspeed <multiplier>` — scales whatever throttle the take asked for.
    static var speedScale: Double? { number("-labspeed") }
    /// `-labwidth <metres>` — how much floor fits across the frame.
    static var frameWidth: Double? { number("-labwidth") }

    static var showsGrid: Bool { !flag("-labnogrid") }
    static var showsRuler: Bool { !flag("-labnoruler") }

    /// `-labshot <path>` — one PNG, then quit.
    static var shotPath: String? { value("-labshot") }
    /// `-labsheet <path>` — a captioned filmstrip, then quit.
    static var sheetPath: String? { value("-labsheet") }
    /// Frames in a filmstrip. Ignored by `-labtake all`, which uses one per take.
    static var sheetFrames: Int { number("-labframes").map { Int($0) } ?? 8 }
    /// `-labbones` — print each model's matched skeleton alongside a report. One line per
    /// canonical bone, saying which joint of the file it found and whether it took a roll — which
    /// is the quickest way in when a limb is drawn at an orientation the rig did not ask for.
    static var wantsSkeletonReport: Bool { flag("-labbones") }

    /// `-labreport <path>` — measurements as JSON, then quit. No GPU needed.
    static var reportPath: String? { value("-labreport") }
    /// How many instants each take is sampled at in a report.
    static var reportSamples: Int { number("-labsamples").map { Int($0) } ?? 48 }

    static var quitsAfterCapture: Bool { shotPath != nil || sheetPath != nil }

    /// `-labsize <width> <height>` — the render size for a capture. The default is a 3:2 frame
    /// big enough to read a knee in.
    static var captureSize: (width: Int, height: Int) {
        let arguments = ProcessInfo.processInfo.arguments
        if let index = arguments.firstIndex(of: "-labsize"), index + 2 < arguments.count,
           let width = Int(arguments[index + 1]), let height = Int(arguments[index + 2]) {
            return (max(200, width), max(200, height))
        }
        return (900, 600)
    }

    /// `-labquitafter <seconds>` — run the window for a while, print what the lab ended up
    /// showing, and quit. A scripted smoke test of the interactive path: it is the one half of
    /// the tool a `-labshot` cannot check, because the capture composites only the Metal frame
    /// and none of the AppKit chrome around it.
    static var quitAfterSeconds: Double? { number("-labquitafter") }

    /// Seconds to let model loading settle before the first grab. The heads and shoes are glTF
    /// files read off disk on a background queue; grabbing before they land photographs a
    /// character with no head, which looks exactly like a bug in the rig.
    static var warmUpSeconds: Double { number("-labwarmup") ?? 2.5 }

    // MARK: - Parsing

    private static func flag(_ name: String) -> Bool {
        ProcessInfo.processInfo.arguments.contains(name)
    }

    private static func value(_ name: String) -> String? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: name), index + 1 < arguments.count else { return nil }
        return arguments[index + 1]
    }

    private static func number(_ name: String) -> Double? {
        value(name).flatMap(Double.init)
    }
}
