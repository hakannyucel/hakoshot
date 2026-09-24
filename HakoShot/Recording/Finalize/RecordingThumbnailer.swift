import AVFoundation
import CoreGraphics
import Foundation

/// Poster frame of a finished recording for Quick Access and History
/// (kayit-teknik-plan §4.14): the frame at 10 % of the duration or 0.5 s,
/// whichever is earlier, at most `maxDimension` px on the long side.
nonisolated enum RecordingThumbnailer {
    static let maxDimension: CGFloat = 480

    /// Plan §4.14 poster time for a clip of `duration` seconds.
    static func posterTime(forDuration duration: Double) -> Double {
        guard duration.isFinite, duration > 0 else { return 0 }
        return min(duration * 0.1, 0.5)
    }

    /// `time` `nil` = `posterTime(forDuration:)`. Throws `RecordingError.finalizeFailed`.
    static func thumbnail(
        for url: URL,
        duration: Double? = nil,
        at time: Double? = nil,
        maxDimension: CGFloat = maxDimension
    ) async throws -> CGImage {
        let asset = AVURLAsset(url: url)
        let seconds: Double
        if let time {
            seconds = time
        } else if let duration {
            seconds = posterTime(forDuration: duration)
        } else {
            seconds = posterTime(forDuration: (try? await asset.load(.duration).seconds) ?? 0)
        }
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: maxDimension, height: maxDimension)
        generator.requestedTimeToleranceBefore = CMTime(value: 1, timescale: 10)
        generator.requestedTimeToleranceAfter = CMTime(value: 1, timescale: 10)
        do {
            return try await generator.image(at: CMTime(seconds: seconds, preferredTimescale: 600)).image
        } catch {
            // Very short clips: fall back to the first frame.
            do {
                generator.requestedTimeToleranceAfter = .positiveInfinity
                return try await generator.image(at: .zero).image
            } catch {
                throw RecordingError.finalizeFailed("thumbnail: \(error.localizedDescription)")
            }
        }
    }
}
