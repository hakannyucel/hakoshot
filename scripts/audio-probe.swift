#!/usr/bin/env swift
// For each audio track in a file, prints the RMS level in dBFS over the
// whole track plus, per channel, the dominant frequency (via a real FFT over
// a 1 s window near the start of the track). Used to verify R2/R3 audio
// acceptance tests (e.g. a synthetic 440/880 Hz stereo test tone).
//
// Usage: swift scripts/audio-probe.swift <file>

import Accelerate
import AVFoundation
import CoreMedia
import Foundation

func fail(_ message: String) -> Never {
    FileHandle.standardError.write("audio-probe: \(message)\n".data(using: .utf8)!)
    exit(1)
}

func printJSON(_ object: Any) {
    guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]) else {
        fail("could not serialize JSON")
    }
    print(String(data: data, encoding: .utf8) ?? "{}")
}

// MARK: - PCM extraction

/// Reads an audio track as 32-bit float, non-interleaved PCM and returns one
/// Float array per channel.
func readChannels(track: AVAssetTrack, asset: AVAsset, channelCount: Int) throws -> [[Float]] {
    let reader = try AVAssetReader(asset: asset)
    let outputSettings: [String: Any] = [
        AVFormatIDKey: kAudioFormatLinearPCM,
        AVLinearPCMBitDepthKey: 32,
        AVLinearPCMIsFloatKey: true,
        AVLinearPCMIsNonInterleaved: true,
        AVLinearPCMIsBigEndianKey: false,
    ]
    let output = AVAssetReaderTrackOutput(track: track, outputSettings: outputSettings)
    output.alwaysCopiesSampleData = false
    guard reader.canAdd(output) else {
        fail("could not attach reader output")
    }
    reader.add(output)
    guard reader.startReading() else {
        fail("AVAssetReader.startReading failed: \(reader.error?.localizedDescription ?? "unknown")")
    }

    var channels = Array(repeating: [Float](), count: max(channelCount, 1))

    while let sampleBuffer = output.copyNextSampleBuffer() {
        let listPointer = AudioBufferList.allocate(maximumBuffers: max(channelCount, 1))
        defer { free(listPointer.unsafeMutablePointer) }
        var blockBuffer: CMBlockBuffer?
        let status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: nil,
            bufferListOut: listPointer.unsafeMutablePointer,
            bufferListSize: AudioBufferList.sizeInBytes(maximumBuffers: max(channelCount, 1)),
            blockBufferAllocator: nil,
            blockBufferMemoryAllocator: nil,
            flags: kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment,
            blockBufferOut: &blockBuffer
        )
        guard status == noErr else { continue }

        for (channelIndex, buffer) in listPointer.enumerated() where channelIndex < channels.count {
            guard let data = buffer.mData else { continue }
            let frameCount = Int(buffer.mDataByteSize) / MemoryLayout<Float>.size
            let floatPointer = data.bindMemory(to: Float.self, capacity: frameCount)
            channels[channelIndex].append(contentsOf: UnsafeBufferPointer(start: floatPointer, count: frameCount))
        }
    }

    if reader.status == .failed {
        fail("AVAssetReader failed: \(reader.error?.localizedDescription ?? "unknown")")
    }

    return channels
}

// MARK: - Analysis

func rmsDBFS(_ samples: [Float]) -> Double {
    guard !samples.isEmpty else { return -Double.greatestFiniteMagnitude }
    var meanSquare: Float = 0
    vDSP_measqv(samples, 1, &meanSquare, vDSP_Length(samples.count))
    let rms = Double(sqrt(meanSquare))
    let floor = 1e-9
    return 20 * log10(max(rms, floor))
}

/// Dominant frequency (Hz) via a real FFT over up to `sampleRate` samples
/// (i.e. approximately a 1 s window) starting at the beginning of `samples`.
func dominantFrequency(_ samples: [Float], sampleRate: Double) -> Double {
    let maxWindow = Int(sampleRate)
    let windowLength = min(samples.count, maxWindow)
    guard windowLength >= 16 else { return 0 }

    let log2n = vDSP_Length(log2(Double(windowLength)).rounded(.down))
    let n = 1 << log2n
    guard n >= 16 else { return 0 }

    var windowed = Array(samples[0..<n])
    var hann = [Float](repeating: 0, count: n)
    vDSP_hann_window(&hann, vDSP_Length(n), Int32(vDSP_HANN_NORM))
    vDSP_vmul(windowed, 1, hann, 1, &windowed, 1, vDSP_Length(n))

    guard let fftSetup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else {
        return 0
    }
    defer { vDSP_destroy_fftsetup(fftSetup) }

    var realParts = [Float](repeating: 0, count: n / 2)
    var imagParts = [Float](repeating: 0, count: n / 2)
    var magnitudes = [Float](repeating: 0, count: n / 2)

    realParts.withUnsafeMutableBufferPointer { realBuffer in
        imagParts.withUnsafeMutableBufferPointer { imagBuffer in
            var splitComplex = DSPSplitComplex(realp: realBuffer.baseAddress!, imagp: imagBuffer.baseAddress!)
            windowed.withUnsafeBufferPointer { windowedBuffer in
                windowedBuffer.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: n / 2) { complexPointer in
                    vDSP_ctoz(complexPointer, 2, &splitComplex, 1, vDSP_Length(n / 2))
                }
            }
            vDSP_fft_zrip(fftSetup, &splitComplex, 1, log2n, FFTDirection(FFT_FORWARD))
            vDSP_zvmags(&splitComplex, 1, &magnitudes, 1, vDSP_Length(n / 2))
        }
    }

    // Bin 0 is DC; skip it when looking for the dominant tone.
    var peakIndex = 1
    var peakValue: Float = magnitudes.count > 1 ? magnitudes[1] : 0
    if magnitudes.count > 1 {
        for i in 2..<magnitudes.count {
            if magnitudes[i] > peakValue {
                peakValue = magnitudes[i]
                peakIndex = i
            }
        }
    }
    return Double(peakIndex) * sampleRate / Double(n)
}

// MARK: - Entry point

let arguments = CommandLine.arguments
guard arguments.count == 2 else {
    fail("usage: swift scripts/audio-probe.swift <file>")
}
let inputURL = URL(fileURLWithPath: arguments[1])
guard FileManager.default.fileExists(atPath: inputURL.path) else {
    fail("file not found: \(inputURL.path)")
}

let asset = AVURLAsset(url: inputURL)

func run() async throws {
    let tracks = try await asset.loadTracks(withMediaType: .audio)
    var trackResults: [[String: Any]] = []

    for (index, track) in tracks.enumerated() {
        let formatDescriptions = try await track.load(.formatDescriptions)
        guard
            let formatDescription = formatDescriptions.first,
            let asbdPointer = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription)
        else {
            continue
        }
        let sampleRate = asbdPointer.pointee.mSampleRate
        let channelCount = Int(asbdPointer.pointee.mChannelsPerFrame)

        let channels = try readChannels(track: track, asset: asset, channelCount: channelCount)
        var channelResults: [[String: Any]] = []
        for (channelIndex, samples) in channels.enumerated() {
            let rms = rmsDBFS(samples)
            let frequency = dominantFrequency(samples, sampleRate: sampleRate)
            channelResults.append([
                "channel": channelIndex,
                "rmsDBFS": rms,
                "dominantFrequencyHz": frequency,
            ])
        }

        trackResults.append([
            "index": index,
            "channelCount": channelCount,
            "sampleRate": sampleRate,
            "channels": channelResults,
        ])
    }

    printJSON(["tracks": trackResults])
}

do {
    try await run()
} catch {
    fail("could not analyze audio: \(error)")
}
