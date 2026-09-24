import CoreGraphics
import HakoKit
import Synchronization

/// The editor's images by asset ID. Shared with the renderer's resolver (which
/// may run off the main thread), so it is lock-protected; grows when the
/// Background panel adds a wallpaper / custom image.
nonisolated final class EditorAssetBox: Sendable {
    private let storage: Mutex<[AssetID: CGImage]>

    init(_ assets: [AssetID: CGImage] = [:]) {
        storage = Mutex(assets)
    }

    var all: [AssetID: CGImage] { storage.withLock { $0 } }

    func image(for id: AssetID) -> CGImage? {
        storage.withLock { $0[id] }
    }

    func insert(_ image: CGImage, for id: AssetID) {
        storage.withLock { $0[id] = image }
    }
}
