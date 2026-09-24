import AppKit
import HakoKit

extension SettingsKey where Value == Bool {
    /// Settings > General "Play sounds" (plan §5.4), default on.
    static var playShutterSound: SettingsKey<Bool> {
        SettingsKey("playShutterSound", default: true)
    }
}

/// The camera-shutter sound played after a capture.
enum ShutterSound {
    private static let candidates = [
        "/System/Library/Components/CoreAudio.component/Contents/SharedSupport/SystemSounds/system/Screen Capture.aif",
        "/System/Library/Components/CoreAudio.component/Contents/SharedSupport/SystemSounds/system/Grab.aif",
    ]

    private static let sound: NSSound? = {
        for path in candidates where FileManager.default.fileExists(atPath: path) {
            if let sound = NSSound(contentsOfFile: path, byReference: true) {
                return sound
            }
        }
        return NSSound(named: "Tink")
    }()

    static var isEnabled: Bool {
        let key = SettingsKey<Bool>.playShutterSound
        return UserDefaults.standard.object(forKey: key.name) as? Bool ?? key.defaultValue
    }

    /// Plays the shutter sound unless disabled in settings.
    static func play() {
        guard isEnabled, let sound else { return }
        sound.stop()
        sound.play()
    }
}
