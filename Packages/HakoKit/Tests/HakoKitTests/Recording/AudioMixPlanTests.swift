import Foundation
import Testing
@testable import HakoKit

@Suite("AudioMixPlan")
struct AudioMixPlanTests {
    static let loud: [Float] = [0.5, 0.5]
    static let leftOnly: [Float] = [0.5, 0]

    static func mic(_ peaks: [Float]? = loud) -> AudioMixInput { AudioMixInput(role: .microphone, channelCount: 2, channelPeaks: peaks) }
    static func system(_ peaks: [Float]? = loud) -> AudioMixInput { AudioMixInput(role: .system, channelCount: 2, channelPeaks: peaks) }

    @Test func noTracksNeedNothing() {
        let plan = AudioMixPlan(settings: .standard, inputs: [])
        #expect(plan.outputs.isEmpty)
        #expect(!plan.needsProcessing)
        #expect(!AudioMixPlan(settings: AudioMixSettings(mono: true), inputs: []).needsProcessing)
    }

    @Test func oneStereoTrackIsPassthrough() {
        for layout in AudioMixLayout.allCases {
            let plan = AudioMixPlan(settings: AudioMixSettings(layout: layout), inputs: [Self.system()])
            #expect(plan.outputs.count == 1)
            #expect(plan.outputs[0].channelCount == 2)
            #expect(!plan.needsProcessing, "\(layout)")
        }
        // Unanalyzed mic: no fix possible, still a copy.
        #expect(!AudioMixPlan(settings: .standard, inputs: [Self.mic(nil)]).needsProcessing)
    }

    @Test func singleMixesBothIntoOneStereoTrack() {
        let plan = AudioMixPlan(settings: .standard, inputs: [Self.mic(), Self.system()])
        #expect(plan.needsProcessing)
        #expect(plan.outputs.count == 1)
        let track = plan.outputs[0]
        #expect(track.channelCount == 2)
        #expect(track.roles == [.microphone, .system])
        #expect(track.sources.allSatisfy { $0.matrix == [[1, 0], [0, 1]] })
        #expect(track.bitrate == 128_000)
    }

    @Test func separateKeepsTwoTracksInOrder() {
        let plan = AudioMixPlan(settings: AudioMixSettings(layout: .separate), inputs: [Self.mic(), Self.system()])
        #expect(plan.outputs.map(\.roles) == [[.microphone], [.system]])
        #expect(plan.outputs.allSatisfy { $0.channelCount == 2 })
        #expect(!plan.needsProcessing)
    }

    @Test func monoDownmixes() {
        let single = AudioMixPlan(settings: AudioMixSettings(mono: true), inputs: [Self.mic(), Self.system()])
        #expect(single.outputs.count == 1)
        #expect(single.outputs[0].channelCount == 1)
        #expect(single.outputs[0].sources.allSatisfy { $0.matrix == [[0.5, 0.5]] })
        #expect(single.outputs[0].bitrate == 64_000)
        #expect(single.needsProcessing)

        let separate = AudioMixPlan(settings: AudioMixSettings(layout: .separate, mono: true), inputs: [Self.mic(), Self.system()])
        #expect(separate.outputs.map(\.channelCount) == [1, 1])
        #expect(separate.needsProcessing)

        let one = AudioMixPlan(settings: AudioMixSettings(mono: true), inputs: [Self.system()])
        #expect(one.outputs.map(\.channelCount) == [1])
        #expect(one.needsProcessing)
    }

    @Test func silentMicChannelIsDuplicated() {
        let plan = AudioMixPlan(settings: .standard, inputs: [Self.mic(Self.leftOnly)])
        #expect(plan.silentChannelFixes == [0: 0])
        #expect(plan.outputs[0].sources[0].matrix == [[1, 0], [1, 0]])
        #expect(plan.needsProcessing)

        let right = AudioMixPlan(settings: AudioMixSettings(layout: .separate), inputs: [Self.mic([0, 0.2]), Self.system()])
        #expect(right.silentChannelFixes == [0: 1])
        #expect(right.outputs[0].sources[0].matrix == [[0, 1], [0, 1]])
        #expect(right.outputs[1].sources[0].isIdentity)
        #expect(right.needsProcessing)

        // Mono takes the audible channel unscaled instead of halving it.
        let mono = AudioMixPlan(settings: AudioMixSettings(mono: true), inputs: [Self.mic(Self.leftOnly)])
        #expect(mono.outputs[0].sources[0].matrix == [[1, 0]])
    }

    @Test func silentChannelOnlyForMicrophoneAndOnlyOneSided() {
        #expect(AudioMixPlan(settings: .standard, inputs: [Self.system(Self.leftOnly)]).silentChannelFixes.isEmpty)
        #expect(AudioMixPlan.audibleChannel(peaks: [0, 0]) == nil) // all silent: nothing to copy
        #expect(AudioMixPlan.audibleChannel(peaks: [0.5, 0.4]) == nil)
        #expect(AudioMixPlan.audibleChannel(peaks: [0.0001, 0.5]) == 1)
        #expect(AudioMixPlan.audibleChannel(peaks: [0.5, 0.0002]) == 0)
        // Quiet but not silent (−65 dBFS) stays as is.
        #expect(AudioMixPlan.audibleChannel(peaks: [0.5, 0.00056]) == nil)
        #expect(AudioMixPlan.audibleChannel(peaks: [0.5]) == nil)
    }

    @Test func monoInputsAreSpreadToStereo() {
        let plan = AudioMixPlan(settings: .standard, inputs: [AudioMixInput(role: .microphone, channelCount: 1)])
        #expect(plan.outputs[0].sources[0].matrix == [[1], [1]])
        #expect(plan.needsProcessing)
        let mono = AudioMixPlan(settings: AudioMixSettings(mono: true), inputs: [AudioMixInput(role: .microphone, channelCount: 1)])
        #expect(!mono.needsProcessing)
    }

    @Test func gainsScaleMatrices() {
        let settings = AudioMixSettings(gains: [.microphone: 2, .system: 0.5])
        let plan = AudioMixPlan(settings: settings, inputs: [Self.mic(), Self.system()])
        #expect(plan.outputs[0].sources[0].matrix == [[2, 0], [0, 2]])
        #expect(plan.outputs[0].sources[1].matrix == [[0.5, 0], [0, 0.5]])
        // A gain on a copied track forces processing.
        #expect(AudioMixPlan(settings: AudioMixSettings(layout: .separate, gains: [.system: 0.5]), inputs: [Self.system()]).needsProcessing)
        #expect(AudioMixSettings(gains: [.system: -1]).gain(for: .system) == 0)
    }

    @Test func renderSumsAndClamps() {
        let plan = AudioMixPlan(settings: .standard, inputs: [Self.mic(Self.leftOnly), Self.system()])
        // 2 frames of interleaved stereo each.
        let mic: [Float] = [0.25, 0, 0.5, 0]
        let system: [Float] = [0.1, -0.1, 0.8, 0.7]
        let out = plan.outputs[0].render(inputs: [mic, system], frameCount: 2)
        #expect(out.count == 4)
        #expect(abs(out[0] - 0.35) < 1e-6)
        #expect(abs(out[1] - 0.15) < 1e-6)
        #expect(out[2] == 1) // 1.3 clamped
        #expect(abs(out[3] - 1) < 1e-6) // 1.2 clamped

        let mono = AudioMixPlan(settings: AudioMixSettings(mono: true), inputs: [Self.system()])
        let down = mono.outputs[0].render(inputs: [[0.2, 0.4, -0.2, 0]], frameCount: 2)
        #expect(down.count == 2)
        #expect(abs(down[0] - 0.3) < 1e-6 && abs(down[1] + 0.1) < 1e-6)

        // Short input: skipped instead of reading past it.
        #expect(plan.outputs[0].render(inputs: [[0.1], system], frameCount: 2) == system.map { min(1, $0) })
        #expect(plan.outputs[0].render(inputs: [mic, system], frameCount: 0).isEmpty)
    }
}
