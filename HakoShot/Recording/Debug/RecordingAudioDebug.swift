#if DEBUG
import Foundation
import HakoKit
import os

/// DEBUG audio helpers (plan §7 R2.1, R2.2):
/// `hakoshot://debug-audio-devices?out=<json>` writes the input device list;
/// `hakoshot://debug-finalize?filepath=<raw.mov>&tracks=single|separate&mono=0|1&out=<mp4>`
/// runs the finalizer's audio mix on a raw file (`kinds=mic,system` names
/// its audio tracks; default: 2 tracks = mic, system, 1 track = system).
enum RecordingAudioDebug {
    nonisolated struct FinalizeParameters: Sendable, Equatable {
        var file: URL
        var out: URL
        var settings: AudioMixSettings
        var kinds: [AudioTrackKind]

        /// For `AppCommand.description`.
        var summary: String {
            "\(file.lastPathComponent), \(settings.layout.rawValue)\(settings.mono ? ", mono" : "")"
        }

        /// `nil` without `filepath` / `out` or with an unknown `tracks` / `kinds` value.
        init?(queryItems: [URLQueryItem]) {
            func value(_ name: String) -> String? {
                queryItems.first { $0.name.lowercased() == name }?.value?.trimmingCharacters(in: .whitespaces)
            }
            func fileURL(_ raw: String?) -> URL? {
                guard let raw, !raw.isEmpty else { return nil }
                return URL(fileURLWithPath: (raw as NSString).expandingTildeInPath)
            }
            guard let file = fileURL(value("filepath") ?? value("path")), let out = fileURL(value("out")) else { return nil }
            guard let layout = AudioMixLayout(rawValue: (value("tracks") ?? "single").lowercased()) else { return nil }
            let mono = ["1", "true", "yes"].contains((value("mono") ?? "0").lowercased())
            var kinds: [AudioTrackKind] = []
            for part in (value("kinds") ?? "").lowercased().split(separator: ",") {
                switch part.trimmingCharacters(in: .whitespaces) {
                case "mic", "microphone": kinds.append(.microphone)
                case "system", "sys": kinds.append(.system)
                default: return nil
                }
            }
            self.file = file
            self.out = out
            settings = AudioMixSettings(layout: layout, mono: mono)
            self.kinds = kinds
        }
    }

    /// `debug-finalize` entry point: writes `out` and logs the plan.
    nonisolated static func finalize(_ parameters: FinalizeParameters) async {
        do {
            let report = try await RecordingFinalizer.convert(
                parameters.file, to: parameters.out, roles: parameters.kinds, audio: parameters.settings
            )
            let outputs = report.plan.outputs.map { "\($0.roles.map(\.rawValue).joined(separator: "+")):\($0.channelCount)ch" }
            Log.recording.notice("debug-finalize wrote \(parameters.out.path, privacy: .public): \(report.mixed ? "mixed" : "remuxed", privacy: .public) [\(outputs.joined(separator: ", "), privacy: .public)] fixes \(report.plan.silentChannelFixes.count)")
        } catch {
            Log.recording.error("debug-finalize failed: \(String(describing: error), privacy: .public)")
        }
    }

    /// JSON: `{"defaultDeviceID": …, "devices": [{"id", "name", "isExternal"}], "microphoneAuthorization": …}`.
    nonisolated static func audioDevicesJSON(_ list: MicrophoneDeviceList = .current(), authorization: MediaAuthorization = MediaPermissions.microphone) throws -> Data {
        var object: [String: Any] = [
            "devices": list.devices.map { ["id": $0.id, "name": $0.name, "isExternal": $0.isExternal] },
            "microphoneAuthorization": authorization.rawValue,
        ]
        object["defaultDeviceID"] = list.defaultDeviceID ?? NSNull()
        return try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
    }

    /// `debug-audio-devices?out=` entry point; logs errors.
    nonisolated static func writeAudioDevices(to url: URL) {
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try audioDevicesJSON().write(to: url, options: .atomic)
            Log.recording.notice("debug-audio-devices wrote \(url.path, privacy: .public)")
        } catch {
            Log.recording.error("debug-audio-devices failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}
#endif
