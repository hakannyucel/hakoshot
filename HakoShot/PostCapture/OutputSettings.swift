import Foundation
import HakoKit

/// Output-related `SettingsKey`s (plan §5.4) and the `AppSettings`
/// convenience reads built on top of them. Declared here, not in
/// `Settings/AppSettings.swift`, so that file stays a small, feature-agnostic
/// reader (see its header comment).
extension SettingsKey where Value == String {
    /// Folder captures are saved into. `~` is expanded by `OutputService`
    /// before use. Default: `~/Desktop` (plan §5.4).
    static var outputSaveFolderPath: SettingsKey<String> {
        SettingsKey(
            "outputSaveFolderPath",
            default: FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Desktop", isDirectory: true)
                .path
        )
    }

    /// `FileNameTemplate.pattern` (plan §5.4 token set: `%Y %y %m %B %d %H %h
    /// %M %S %p %n %mode`). Default mirrors `FileNameTemplate.default`.
    static var outputFileNameTemplate: SettingsKey<String> {
        SettingsKey("outputFileNameTemplate", default: FileNameTemplate.default.pattern)
    }
}

extension SettingsKey where Value == ImageFormat {
    /// Default export format. Default: PNG (plan §5.4).
    static var outputImageFormat: SettingsKey<ImageFormat> {
        SettingsKey("outputImageFormat", default: .png)
    }
}

extension SettingsKey where Value == Double {
    /// Lossy compression quality per format, 0...1 (plan §5.4 defaults: JPEG
    /// 0.85, HEIC 0.80, WebP 0.85; PNG is lossless and ignores this).
    static var outputJPEGQuality: SettingsKey<Double> {
        SettingsKey("outputJPEGQuality", default: 0.85)
    }

    static var outputHEICQuality: SettingsKey<Double> {
        SettingsKey("outputHEICQuality", default: 0.80)
    }

    static var outputWebPQuality: SettingsKey<Double> {
        SettingsKey("outputWebPQuality", default: 0.85)
    }
}

extension SettingsKey where Value == Bool {
    /// Settings > General > After capture > "Save". Whether a capture is
    /// written to disk with no explicit `PostCaptureAction` override. Default
    /// off (plan §5.4): Quick Access Save / auto-close writes the file instead.
    /// (M1 defaulted this to `true` before Quick Access existed.)
    static var outputSaveToDiskOnCapture: SettingsKey<Bool> {
        SettingsKey("outputSaveToDiskOnCapture", default: false)
    }

    /// Settings > General > After capture > "Copy". Whether a capture is
    /// copied to the pasteboard with no explicit `PostCaptureAction` override.
    /// Default off (plan §5.4).
    static var outputCopyToClipboardOnCapture: SettingsKey<Bool> {
        SettingsKey("outputCopyToClipboardOnCapture", default: false)
    }

    /// When a capture's `PostCaptureAction` override is explicitly `.copy`
    /// (e.g. `hakoshot://capture-area?action=copy`), whether it is *also*
    /// written to disk. Default off — an explicit "just copy" request should
    /// not leave a file behind.
    static var outputCopyAlsoSavesToDisk: SettingsKey<Bool> {
        SettingsKey("outputCopyAlsoSavesToDisk", default: false)
    }

    /// Settings > Advanced > "Scale Retina screenshots to 1x". When on and a
    /// capture's `CaptureResult.scale` is > 1, `OutputService` downsamples
    /// the saved file to its point size (72 DPI) instead of the native pixel
    /// grid. Default off (plan §4.7 / §5.4: files are saved at native Retina
    /// resolution by default).
    static var outputScaleRetinaTo1x: SettingsKey<Bool> {
        SettingsKey("outputScaleRetinaTo1x", default: false)
    }

    /// Settings > Advanced > "Add @2x suffix to Retina files". When on,
    /// `OutputService` appends `"@Nx"` (e.g. `"@2x"`) to the file name of a
    /// capture that's still saved at > 1x resolution — i.e. this has no
    /// effect once `outputScaleRetinaTo1x` has downsampled it back to 1x.
    /// Default off (plan §4.7 / §5.4).
    static var outputAppendsRetinaSuffix: SettingsKey<Bool> {
        SettingsKey("outputAppendsRetinaSuffix", default: false)
    }
}

extension AppSettings {
    /// The configured lossy compression quality for `format` (ignored by
    /// `ImageEncoder` for PNG, which is always lossless).
    func outputQuality(for format: ImageFormat) -> Double {
        switch format {
        case .png: return 1.0
        case .jpeg: return value(for: .outputJPEGQuality)
        case .heic: return value(for: .outputHEICQuality)
        case .webp: return value(for: .outputWebPQuality)
        }
    }
}
