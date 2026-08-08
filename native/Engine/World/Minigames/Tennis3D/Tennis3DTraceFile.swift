import Foundation

/// **Where `-tennis3dtrace` writes when nobody is holding the other end of a pipe.**
///
/// Six sessions of handoff notes have been slowed down by the same thing: the only way to read
/// the trace was `xcrun simctl launch --console-pty`, and that pipe dies. Sometimes it takes the
/// app with it, and sometimes — worse — the app plays merrily on while the log simply stops
/// growing, so a run that looks finished after two points has actually played twenty and thrown
/// eighteen of them away. Every balance number in parts 2 to 6 was measured through that pipe.
///
/// A file in the app's own container has neither problem. It survives the pipe, it survives the
/// launching shell being reaped, and it can be read at any point during or after a run:
///
/// ```bash
/// DIR=$(xcrun simctl get_app_container <udid> com.allr.joelsworld data)
/// cat "$DIR/Documents/tennis3d-trace.log"
/// ```
///
/// DEBUG only, and only when the flag is on, so it costs a shipping build nothing.
#if DEBUG
enum Tennis3DTraceFile {

    /// Appended to for the life of the process. Truncated once, at the first line of a run, so a
    /// relaunch does not silently analyse the previous match's rallies as well as this one's.
    private static var handle: FileHandle?
    private static var started = false

    static func write(_ line: String) {
        guard WalkTest.traces3DTennis else { return }
        guard let handle = openIfNeeded() else { return }
        handle.write(Data((line + "\n").utf8))
    }

    private static func openIfNeeded() -> FileHandle? {
        if let handle { return handle }
        guard !started else { return nil }
        started = true

        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)
        guard let directory = documents.first else { return nil }
        let url = directory.appendingPathComponent("tennis3d-trace.log")

        FileManager.default.createFile(atPath: url.path, contents: nil)
        handle = try? FileHandle(forWritingTo: url)
        return handle
    }
}
#endif
