import Foundation

/// Builds the on-disk `URLCache` the tile and model loaders share the shape of.
///
/// `URLCache(memoryCapacity:diskCapacity:diskPath:)` takes a *relative* path, and on macOS an
/// unsandboxed process resolves that against its current working directory — so the admin
/// editor scattered `joelsworld-tiles/` and `joelsworld-models/` folders into whatever
/// directory it happened to be launched from, this repository included. Anchoring the
/// directory explicitly puts both platforms in the caches directory, where it belongs.
enum DiskCache {
    static func make(name: String, memoryCapacity: Int, diskCapacity: Int) -> URLCache {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
        guard let directory = caches?.appendingPathComponent("com.allr.joelsworld/\(name)") else {
            return URLCache(memoryCapacity: memoryCapacity, diskCapacity: diskCapacity, diskPath: name)
        }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return URLCache(memoryCapacity: memoryCapacity, diskCapacity: diskCapacity, directory: directory)
    }
}
