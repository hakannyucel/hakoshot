import AVFoundation
import HakoKit
import Observation
import SwiftUI

/// Thumbnail strip layout (plan §4.16: strip width / 48 pt thumbnails).
nonisolated enum ThumbnailStripLayout {
    /// Thumbnails needed to fill `width` (the last one is clipped), ≥ 1.
    static func count(forWidth width: CGFloat, thumbnailWidth: CGFloat = VideoEditorMetrics.thumbnailWidth) -> Int {
        guard width.isFinite, width > 0, thumbnailWidth > 0 else { return 1 }
        return max(1, Int((width / thumbnailWidth - 1e-6).rounded(.up)))
    }

    /// Source time shown by each thumbnail: the time under its center, for
    /// a strip `width` wide covering `duration` seconds.
    static func times(count: Int, width: CGFloat, duration: Double, thumbnailWidth: CGFloat = VideoEditorMetrics.thumbnailWidth) -> [Double] {
        guard count > 0, width > 0, duration > 0 else { return [] }
        return (0..<count).map { index in
            let center = min(Double(index) * Double(thumbnailWidth) + Double(thumbnailWidth) / 2, Double(width))
            return min(center / Double(width) * duration, max(0, duration - 0.001))
        }
    }
}

/// Generates the strip's thumbnails asynchronously with
/// `AVAssetImageGenerator.images(for:)`; a new width restarts the batch.
@Observable
final class ThumbnailLoader {
    private(set) var images: [Int: CGImage] = [:]
    private(set) var count = 0
    private(set) var isComplete = false
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var loadedKey: Key?

    private struct Key: Equatable {
        var count: Int
        var width: CGFloat
        var height: CGFloat
    }

    /// Loads `count(forWidth: width)` thumbnails of `asset` (`duration`
    /// seconds) at `height` points. No-op when nothing changed.
    func load(asset: AVAsset, duration: Double, width: CGFloat, height: CGFloat) {
        let count = ThumbnailStripLayout.count(forWidth: width)
        let key = Key(count: count, width: width.rounded(), height: height.rounded())
        guard key != loadedKey, duration > 0, width > 0 else { return }
        loadedKey = key
        task?.cancel()
        self.count = count
        images = [:]
        isComplete = false
        let times = ThumbnailStripLayout.times(count: count, width: width, duration: duration)
        let scale = VideoEditorMetrics.thumbnailPixelScale
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: VideoEditorMetrics.thumbnailWidth * scale * 2, height: height * scale)
        let tolerance = CMTime(seconds: max(0.05, duration / Double(count) / 2), preferredTimescale: 600)
        generator.requestedTimeToleranceBefore = tolerance
        generator.requestedTimeToleranceAfter = tolerance
        task = Task { [weak self] in
            let requested = times.map { CMTime(seconds: $0, preferredTimescale: 600) }
            for await result in generator.images(for: requested) {
                guard !Task.isCancelled else { return }
                guard let image = try? result.image else { continue }
                let seconds = result.requestedTime.seconds
                guard let index = times.indices.min(by: { abs(times[$0] - seconds) < abs(times[$1] - seconds) }) else { continue }
                self?.images[index] = image
            }
            guard !Task.isCancelled else { return }
            self?.isComplete = true
        }
    }

    func cancel() {
        task?.cancel()
    }
}

/// Row of thumbnails, each `thumbnailWidth` wide, filling the strip.
struct ThumbnailStrip: View {
    let loader: ThumbnailLoader

    var body: some View {
        GeometryReader { proxy in
            HStack(spacing: 0) {
                ForEach(0..<max(loader.count, 1), id: \.self) { index in
                    thumbnail(index, height: proxy.size.height)
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .leading)
            .clipped()
        }
        .background(Color.black.opacity(0.85))
    }

    @ViewBuilder
    private func thumbnail(_ index: Int, height: CGFloat) -> some View {
        let width = VideoEditorMetrics.thumbnailWidth
        if let image = loader.images[index] {
            Image(decorative: image, scale: VideoEditorMetrics.thumbnailPixelScale)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: width, height: height)
                .clipped()
        } else {
            Rectangle()
                .fill(Color.white.opacity(0.06))
                .frame(width: width, height: height)
        }
    }
}
