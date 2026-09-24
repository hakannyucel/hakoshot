import Testing
@testable import HakoKit

@Suite("VideoQuality")
struct VideoQualityTests {
    @Test(arguments: [
        // (quality, width, height, fps, codec, expected bits/s)
        (VideoQuality.low, 1920, 1080, 60, VideoCodec.h264, 2_488_320),
        (.medium, 1920, 1080, 60, .h264, 4_354_560),
        (.high, 1920, 1080, 60, .h264, 6_220_800),
        (.ultra, 1920, 1080, 60, .h264, 9_953_280),
        (.high, 3840, 2160, 60, .h264, 24_883_200),
        (.high, 3840, 2160, 60, .hevc, 17_418_240),
        (.high, 1280, 720, 30, .h264, 2_000_000), // 1 382 400 → floor
        (.ultra, 5120, 2880, 60, .hevc, 49_545_216),
        (.ultra, 6016, 3384, 60, .h264, 97_719_091),
        (.ultra, 7680, 4320, 60, .h264, 100_000_000), // ceiling
        (.ultra, 7680, 4320, 60, .hevc, 80_000_000), // HEVC ceiling
    ])
    func bitrateTable(quality: VideoQuality, width: Int, height: Int, fps: Int, codec: VideoCodec, expected: Int) {
        #expect(quality.bitrate(width: width, height: height, fps: fps, codec: codec) == expected)
    }

    @Test func bppAndDefaults() {
        #expect(VideoQuality.allCases.map(\.bitsPerPixel) == [0.02, 0.035, 0.05, 0.08])
        #expect(VideoQuality.default == .high)
        #expect(VideoQuality.studioRaw == .ultra)
        #expect(VideoCodec.hevc.bitsPerPixelFactor == 0.7)
        #expect(VideoQuality.low.bitrate(width: 0, height: 0, fps: 0) == VideoQuality.minBitrate)
        #expect(VideoQuality(rawValue: "ultra") == .ultra)
        #expect(VideoCodec(rawValue: "hevc") == .hevc)
    }

    @Test func frameRateLists() {
        #expect(RecordingFrameRates.video == [60, 50, 30, 25, 24, 15])
        #expect(RecordingFrameRates.defaultVideo == 60)
        #expect(RecordingFrameRates.gif == [5, 10, 15, 20, 24, 30])
        #expect(RecordingFrameRates.defaultGIF == 15)
        #expect(RecordingFrameRates.nearest(59) == 60)
        #expect(RecordingFrameRates.nearest(27) == 25)
        #expect(RecordingFrameRates.nearest(1000) == 60)
        #expect(RecordingFrameRates.nearest(12, in: RecordingFrameRates.gif) == 10)
        #expect(RecordingFrameRates.nearest(0) == 15)
        #expect(RecordingFrameRates.studioRawFPS(displayRefreshRate: 120) == 60)
        #expect(RecordingFrameRates.studioRawFPS(displayRefreshRate: 59.94) == 60)
        #expect(RecordingFrameRates.studioRawFPS(displayRefreshRate: 50) == 50)
        #expect(RecordingFrameRates.studioRawFPS(displayRefreshRate: 0) == 60)
    }
}
