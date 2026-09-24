import Accelerate
import Foundation

// Finalize audio mix (kayit-teknik-plan §4.7, §4.14): which AAC tracks the
// delivered .mp4 gets from the raw recording's microphone / system tracks.

/// What a raw audio track carries. File order is microphone, system.
public enum AudioMixTrackRole: String, Sendable, Hashable, Codable, CaseIterable {
    case microphone
    case system
}

/// Settings > Recording > Audio "Audio tracks" (same raw values as the app's
/// `RecordingAudioTrackLayout`).
public enum AudioMixLayout: String, Sendable, Hashable, Codable, CaseIterable {
    /// Microphone and system audio mixed into one track (default).
    case single
    /// One track per source, microphone first.
    case separate
}

/// The user's audio choices for one recording.
public struct AudioMixSettings: Sendable, Hashable, Codable {
    public var layout: AudioMixLayout
    /// "Record audio in mono": every output track gets one channel.
    public var mono: Bool
    /// Linear gain per source; missing = 1.
    public var gains: [AudioMixTrackRole: Float]

    public init(layout: AudioMixLayout = .single, mono: Bool = false, gains: [AudioMixTrackRole: Float] = [:]) {
        self.layout = layout
        self.mono = mono
        self.gains = gains
    }

    /// Plan §5 defaults: single track, stereo, unity gain.
    public static let standard = AudioMixSettings()

    public func gain(for role: AudioMixTrackRole) -> Float {
        max(0, gains[role] ?? 1)
    }
}

/// One raw audio track as the plan sees it.
public struct AudioMixInput: Sendable, Hashable {
    public var role: AudioMixTrackRole
    public var channelCount: Int
    /// Peak level per channel over the whole track (linear 0…1); `nil` when
    /// not analyzed (then no silent-channel fix is possible).
    public var channelPeaks: [Float]?

    public init(role: AudioMixTrackRole, channelCount: Int, channelPeaks: [Float]? = nil) {
        self.role = role
        self.channelCount = max(1, channelCount)
        self.channelPeaks = channelPeaks
    }
}

/// How one input feeds one output track: `matrix[outChannel][inChannel]`
/// (gain included).
public struct AudioMixSource: Sendable, Hashable {
    /// Index into the plan's inputs.
    public var inputIndex: Int
    public var role: AudioMixTrackRole
    public var inputChannelCount: Int
    public var matrix: [[Float]]

    public init(inputIndex: Int, role: AudioMixTrackRole, inputChannelCount: Int, matrix: [[Float]]) {
        self.inputIndex = inputIndex
        self.role = role
        self.inputChannelCount = inputChannelCount
        self.matrix = matrix
    }

    /// Plain copy: square identity matrix with unity gain.
    public var isIdentity: Bool {
        guard matrix.count == inputChannelCount else { return false }
        for (row, gains) in matrix.enumerated() {
            guard gains.count == inputChannelCount else { return false }
            for (column, gain) in gains.enumerated() where gain != (row == column ? 1 : 0) { return false }
        }
        return true
    }
}

/// One AAC track of the delivered file.
public struct AudioMixOutputTrack: Sendable, Hashable {
    public var channelCount: Int
    /// Summed in this order.
    public var sources: [AudioMixSource]

    public init(channelCount: Int, sources: [AudioMixSource]) {
        self.channelCount = channelCount
        self.sources = sources
    }

    public var roles: [AudioMixTrackRole] { sources.map(\.role) }

    /// AAC bitrate (plan §5.2: 128 kbps stereo, 64 kbps mono).
    public var bitrate: Int { AudioMixPlan.bitrate(channelCount: channelCount) }

    /// Mixes `frameCount` frames of interleaved Float32 input (`inputs[i]`
    /// holds `frameCount × inputs[i].channelCount` samples, indexed like the
    /// plan's inputs) into interleaved output, clamped to −1…1.
    public func render(inputs: [[Float]], frameCount: Int) -> [Float] {
        var output = [Float](repeating: 0, count: max(0, frameCount) * channelCount)
        guard frameCount > 0 else { return output }
        output.withUnsafeMutableBufferPointer { out in
            guard let outBase = out.baseAddress else { return }
            for source in sources where inputs.indices.contains(source.inputIndex) {
                let input = inputs[source.inputIndex]
                let inChannels = source.inputChannelCount
                guard input.count >= frameCount * inChannels else { continue }
                input.withUnsafeBufferPointer { inBuffer in
                    guard let inBase = inBuffer.baseAddress else { return }
                    for (outChannel, row) in source.matrix.enumerated() where outChannel < channelCount {
                        for (inChannel, gain) in row.enumerated() where gain != 0 && inChannel < inChannels {
                            // out[c] += in[k] * gain, both strided (interleaved).
                            var scale = gain
                            vDSP_vsma(
                                inBase + inChannel, vDSP_Stride(inChannels), &scale,
                                outBase + outChannel, vDSP_Stride(channelCount),
                                outBase + outChannel, vDSP_Stride(channelCount),
                                vDSP_Length(frameCount)
                            )
                        }
                    }
                }
            }
            var low: Float = -1
            var high: Float = 1
            vDSP_vclip(outBase, 1, &low, &high, outBase, 1, vDSP_Length(out.count))
        }
        return output
    }
}

/// Decides the delivered audio tracks from the settings and the raw tracks
/// present (plan §4.7, §4.14):
/// - single: every source summed into one stereo track (mono: one channel);
/// - separate: one track per source in input order (mic, system);
/// - mono: stereo sources are averaged (L+R)/2 into one channel;
/// - silent-channel fix: a stereo microphone track whose one channel is
///   silent (a mono mic on input 1 of a 2-input interface) plays its audible
///   channel on both output channels (or alone, unscaled, in mono).
///
/// `needsProcessing == false` means the tracks can be copied as they are
/// (passthrough remux, no AAC re-encode).
public struct AudioMixPlan: Sendable, Hashable {
    /// A channel whose whole-track peak is at or below this is silent (−70 dBFS).
    public static let silentChannelPeak: Float = 0.000_316_2
    /// The other channel must reach at least this (−60 dBFS) for the fix.
    public static let audibleChannelPeak: Float = 0.001

    public static func bitrate(channelCount: Int) -> Int {
        channelCount <= 1 ? 64_000 : 128_000
    }

    public var settings: AudioMixSettings
    public var inputs: [AudioMixInput]
    public var outputs: [AudioMixOutputTrack]
    /// Input index → the audible channel duplicated by the silent-channel fix.
    public var silentChannelFixes: [Int: Int]

    public init(settings: AudioMixSettings, inputs: [AudioMixInput]) {
        self.settings = settings
        self.inputs = inputs
        var fixes: [Int: Int] = [:]
        for (index, input) in inputs.enumerated() where input.role == .microphone {
            if let peaks = input.channelPeaks, let audible = Self.audibleChannel(peaks: peaks) {
                fixes[index] = audible
            }
        }
        silentChannelFixes = fixes

        let outChannels = settings.mono ? 1 : 2
        func source(_ index: Int) -> AudioMixSource {
            let input = inputs[index]
            let gain = settings.gain(for: input.role)
            let matrix = Self.matrix(
                inputChannels: input.channelCount,
                outputChannels: outChannels,
                keptChannel: fixes[index]
            ).map { $0.map { $0 * gain } }
            return AudioMixSource(inputIndex: index, role: input.role, inputChannelCount: input.channelCount, matrix: matrix)
        }
        if inputs.isEmpty {
            outputs = []
            return
        }
        switch settings.layout {
        case .single:
            outputs = [AudioMixOutputTrack(channelCount: outChannels, sources: inputs.indices.map(source))]
        case .separate:
            outputs = inputs.indices.map { AudioMixOutputTrack(channelCount: outChannels, sources: [source($0)]) }
        }
    }

    /// `false` when every output is one input copied unchanged (same channel
    /// count, identity matrix): the finalizer remuxes instead of re-encoding.
    public var needsProcessing: Bool {
        guard outputs.count == inputs.count else { return true }
        for (index, output) in outputs.enumerated() {
            guard output.sources.count == 1, let source = output.sources.first,
                  source.inputIndex == index,
                  output.channelCount == source.inputChannelCount,
                  source.isIdentity
            else { return true }
        }
        return false
    }

    /// The channel to keep when exactly one channel of a stereo track is
    /// silent and the other is audible; `nil` otherwise.
    public static func audibleChannel(peaks: [Float]) -> Int? {
        guard peaks.count == 2 else { return nil }
        let silent = peaks.map { $0 <= silentChannelPeak }
        let audible = peaks.map { $0 >= audibleChannelPeak }
        if silent[0], audible[1] { return 1 }
        if silent[1], audible[0] { return 0 }
        return nil
    }

    /// `[outChannel][inChannel]` at unity gain. Inputs with more than two
    /// channels use their first two.
    public static func matrix(inputChannels: Int, outputChannels: Int, keptChannel: Int?) -> [[Float]] {
        let inputs = max(1, inputChannels)
        func unit(_ channel: Int) -> [Float] {
            var row = [Float](repeating: 0, count: inputs)
            row[min(channel, inputs - 1)] = 1
            return row
        }
        if let kept = keptChannel, kept < inputs {
            return Array(repeating: unit(kept), count: max(1, outputChannels))
        }
        if outputChannels <= 1 {
            guard inputs > 1 else { return [unit(0)] }
            var row = [Float](repeating: 0, count: inputs)
            row[0] = 0.5
            row[1] = 0.5
            return [row]
        }
        if inputs == 1 { return [unit(0), unit(0)] }
        return [unit(0), unit(1)]
    }
}
