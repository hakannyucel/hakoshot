import Foundation
import Testing
@testable import HakoKit

@Suite("VideoEditRecipe")
struct VideoEditRecipeTests {
    private func sample() -> VideoEditRecipe {
        VideoEditRecipe(
            trim: EditTimeRange(start: 2, end: 7),
            cuts: [EditTimeRange(start: 3, end: 3.5)],
            crop: VideoCropRect(x: 100, y: 50, width: 640, height: 360),
            outputWidth: 1280,
            fps: 30,
            quality: .medium,
            codec: .hevc,
            audio: VideoEditAudio(muted: false, volume: 1.5, mono: true, trackGains: [1, 0.5]),
            format: .gif,
            gif: GIFExportOptions(fps: 10, width: 600, optimize: false, quality: 0.5)
        )
    }

    @Test func jsonRoundTrip() throws {
        let recipe = sample()
        let data = try recipe.jsonData()
        #expect(try VideoEditRecipe.decode(json: data) == recipe)
        #expect(try VideoEditRecipe.decode(json: try recipe.jsonString()) == recipe)
        // Default recipe too.
        #expect(try VideoEditRecipe.decode(json: try VideoEditRecipe().jsonData()) == VideoEditRecipe())
    }

    @Test func jsonIsStable() throws {
        let a = try sample().jsonString()
        let b = try sample().jsonString()
        #expect(a == b)
        #expect(a.hasPrefix(#"{"audio":"#)) // sorted keys
        #expect(a.contains(#""trim":{"end":7,"start":2}"#))
        #expect(!a.contains("scale")) // nil keys are omitted
        let plain = try VideoEditRecipe().jsonString()
        #expect(plain == #"{"audio":{"mono":false,"muted":false,"trackGains":[],"volume":1},"codec":"h264","cuts":[],"format":"mp4","gif":{"fps":15,"optimize":true,"quality":0.8,"width":800},"quality":"high","version":1}"#)
    }

    @Test func partialJSONUsesDefaults() throws {
        let r = try VideoEditRecipe.decode(json: #"{"trim":{"start":2,"end":7},"audio":{"muted":true},"gif":{"fps":20}}"#)
        #expect(r.trim == EditTimeRange(start: 2, end: 7))
        #expect(r.audio.muted)
        #expect(r.audio.volume == 1)
        #expect(r.gif.fps == 20)
        #expect(r.gif.width == 800)
        #expect(r.quality == .high)
        #expect(r.codec == .h264)
        #expect(r.format == .mp4)
        #expect(r.version == VideoEditRecipe.currentVersion)
        #expect(try VideoEditRecipe.decode(json: "{}") == VideoEditRecipe())
        #expect(throws: (any Error).self) { try VideoEditRecipe.decode(json: #"{"codec":"vp9"}"#) }
    }

    @Test func normalizeClamps() {
        var r = VideoEditRecipe()
        r.trim = EditTimeRange(start: 7, end: 2)
        r.cuts = [EditTimeRange(start: 1, end: 1), EditTimeRange(start: .nan, end: 2)]
        r.crop = VideoCropRect(x: 0, y: 0, width: 0, height: 10)
        r.outputWidth = 641
        r.outputHeight = -5
        r.scale = -1
        r.fps = 500
        r.audio = VideoEditAudio(volume: 3, trackGains: [-1, 0.5, .infinity])
        r.gif = GIFExportOptions(fps: 99, width: -10, quality: 4)
        let n = r.normalized()
        #expect(n.trim == EditTimeRange(start: 2, end: 7))
        #expect(n.cuts.isEmpty)
        #expect(n.crop == nil)
        #expect(n.outputWidth == 642)
        #expect(n.outputHeight == nil)
        #expect(n.scale == nil)
        #expect(n.fps == 120)
        #expect(n.audio.volume == 2)
        #expect(n.audio.trackGains == [0, 0.5, 1])
        #expect(n.gif.fps == 50)
        #expect(n.gif.width == 0)
        #expect(n.gif.quality == 1)
        #expect(n.normalized() == n)
    }

    @Test func sourceNormalization() {
        var r = VideoEditRecipe()
        r.trim = EditTimeRange(start: -1, end: 20)
        r.cuts = [EditTimeRange(start: 9, end: 30)]
        r.crop = VideoCropRect(x: 1_801, y: 1_001, width: 500, height: 301)
        let n = r.normalized(sourceWidth: 1920, sourceHeight: 1080, sourceDuration: 10)
        #expect(n.trim == nil) // full length after clamping
        #expect(n.cuts == [EditTimeRange(start: 9, end: 10)])
        // Origin evened down, size clamped to the frame, everything even.
        #expect(n.crop == VideoCropRect(x: 1_800, y: 1_000, width: 120, height: 80))

        var full = VideoEditRecipe()
        full.crop = VideoCropRect(x: 0, y: 0, width: 5000, height: 5000)
        #expect(full.normalized(sourceWidth: 1920, sourceHeight: 1080, sourceDuration: 1).crop == nil)
    }

    @Test func effectiveCropIsEvenAndInside() {
        var r = VideoEditRecipe()
        #expect(r.effectiveCrop(sourceWidth: 1920, sourceHeight: 1080) == VideoCropRect(x: 0, y: 0, width: 1920, height: 1080))
        r.crop = VideoCropRect(x: 101, y: 51, width: 641, height: 361)
        let c = r.effectiveCrop(sourceWidth: 1920, sourceHeight: 1080)
        #expect(c == VideoCropRect(x: 100, y: 50, width: 640, height: 360))
        r.crop = VideoCropRect(x: -20, y: -20, width: 3, height: 1)
        #expect(r.effectiveCrop(sourceWidth: 1920, sourceHeight: 1080) == VideoCropRect(x: 0, y: 0, width: 2, height: 2))
    }

    @Test func outputSize() {
        var r = VideoEditRecipe()
        #expect(r.outputSize(sourceWidth: 1920, sourceHeight: 1080) == (1920, 1080))
        // R3 acceptance: crop 640×360 → output 640×360.
        r.crop = VideoCropRect(x: 100, y: 100, width: 640, height: 360)
        #expect(r.outputSize(sourceWidth: 1920, sourceHeight: 1080) == (640, 360))
        r.scale = 0.5
        #expect(r.outputSize(sourceWidth: 1920, sourceHeight: 1080) == (320, 180))
        r.outputWidth = 1000 // width wins over scale; height follows aspect
        #expect(r.outputSize(sourceWidth: 1920, sourceHeight: 1080) == (1000, 562))
        r.outputWidth = nil
        r.outputHeight = 721
        #expect(r.outputSize(sourceWidth: 1920, sourceHeight: 1080) == (1282, 722))
        r.outputWidth = 99
        #expect(r.outputSize(sourceWidth: 1920, sourceHeight: 1080) == (100, 722))
        r.outputWidth = 100_000
        #expect(r.outputSize(sourceWidth: 1920, sourceHeight: 1080).width == VideoEditRecipe.maxDimension)
    }

    @Test func gifSizeAndFPS() {
        var r = VideoEditRecipe(format: .gif)
        #expect(r.gifOutputSize(sourceWidth: 1920, sourceHeight: 1080) == (800, 450))
        #expect(r.gifOutputSize(sourceWidth: 640, sourceHeight: 360) == (640, 360)) // no upscale
        r.gif.width = 0
        #expect(r.gifOutputSize(sourceWidth: 1920, sourceHeight: 1080) == (1920, 1080))
        #expect(r.outputFPS(sourceFPS: 60) == 15)
        #expect(r.outputFPS(sourceFPS: 10) == 10)
        r.format = .mp4
        #expect(r.outputFPS(sourceFPS: 60) == 60)
        r.fps = 30
        #expect(r.outputFPS(sourceFPS: 60) == 30)
        #expect(r.outputFPS(sourceFPS: 24) == 24)
        #expect(r.outputFPS(sourceFPS: nil) == 30)
    }

    @Test func gifQualityMapping() {
        #expect(GIFExportOptions(quality: 0).paletteColorCount == 64)
        #expect(GIFExportOptions(quality: 1).paletteColorCount == 255)
        #expect(GIFExportOptions(quality: 0.8).paletteColorCount == 217)
        #expect(GIFExportOptions(quality: 0).ditherStrength == 0)
        #expect(abs(GIFExportOptions(quality: 1).ditherStrength - 0.8) < 1e-12)
        #expect(GIFExportOptions.default == GIFExportOptions(fps: 15, width: 800, optimize: true, quality: 0.8))
    }

    @Test func audioGain() {
        let a = VideoEditAudio(volume: 1.5, trackGains: [0.5])
        #expect(a.gain(forTrack: 0) == 0.75)
        #expect(a.gain(forTrack: 1) == 1.5)
        #expect(!a.isUnchanged)
        #expect(VideoEditAudio().isUnchanged)
        #expect(VideoEditAudio(muted: true).gain(forTrack: 0) == 0)
    }

    @Test func timelineFromRecipe() {
        let t = sample().timeline(sourceDuration: 10)
        #expect(t.outputDuration == 4.5)
    }
}
