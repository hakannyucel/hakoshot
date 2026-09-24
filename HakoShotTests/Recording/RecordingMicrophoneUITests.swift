import CoreGraphics
import Foundation
import HakoKit
import Testing
@testable import HakoShot

/// R2.I: microphone access in the HUD / coordinator, the device menu rows and
/// the Audio settings rules. Never touches the real TCC state (fake closures).
@Suite("Recording microphone UI", .serialized)
@MainActor
struct RecordingMicrophoneUITests {
    static func settings() -> (AppSettings, UserDefaults, String) {
        let suite = "com.hakanyucel.hakoshot.tests.mic.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        return (AppSettings(defaults: defaults), defaults, suite)
    }

    /// A fake TCC store: `request` flips `.notDetermined` to `answer`.
    final class FakeAccess {
        var state: MediaAuthorization
        var answer: MediaAuthorization
        var requests = 0

        init(_ state: MediaAuthorization, answer: MediaAuthorization = .denied) {
            self.state = state
            self.answer = answer
        }

        func request() -> Bool {
            requests += 1
            if state == .notDetermined { state = answer }
            return state == .authorized
        }
    }

    static func model(_ settings: AppSettings, _ access: FakeAccess) -> RecordingHUDModel {
        RecordingHUDModel(
            settings: settings,
            microphones: MicrophoneDevices(startObserving: false),
            microphoneAccess: { access.state },
            requestMicrophoneAccess: { access.request() }
        )
    }

    @Test func turningMicOnAsksOnceAndWarnsWhenDenied() async {
        let (settings, defaults, suite) = Self.settings()
        defer { defaults.removePersistentDomain(forName: suite) }
        let access = FakeAccess(.notDetermined, answer: .denied)
        let model = Self.model(settings, access)

        await model.ensureMicrophoneAccess() // mic off: nothing asked
        #expect(access.requests == 0)
        #expect(!model.showsMicrophoneWarning)

        model.set(.microphone, true)
        await model.ensureMicrophoneAccess()
        #expect(access.requests == 1)
        #expect(model.microphoneAccess == .denied)
        #expect(model.showsMicrophoneWarning)

        await model.ensureMicrophoneAccess() // decided: no second prompt
        #expect(access.requests == 1)

        model.set(.microphone, false)
        #expect(!model.showsMicrophoneWarning)
    }

    @Test func grantedAccessShowsNoWarning() async {
        let (settings, defaults, suite) = Self.settings()
        defer { defaults.removePersistentDomain(forName: suite) }
        let access = FakeAccess(.notDetermined, answer: .authorized)
        let model = Self.model(settings, access)
        model.selectMicrophone(deviceID: "usb")
        #expect(model.isOn(.microphone))
        await model.ensureMicrophoneAccess()
        #expect(access.requests == 1)
        #expect(!model.showsMicrophoneWarning)
        #expect(settings.value(for: .recordingMicrophoneDeviceID) == "usb")

        // Reload picks up a denial made elsewhere (System Settings).
        access.state = .denied
        model.reload()
        #expect(model.showsMicrophoneWarning)
    }

    @Test func menuOptionsListDevicesAndKeepMissingSelection() {
        let list = MicrophoneDeviceList(
            devices: [
                MicrophoneDevice(id: "builtin", name: "MacBook Pro Microphone", isExternal: false),
                MicrophoneDevice(id: "usb", name: "USB Mic", isExternal: true),
            ],
            defaultDeviceID: "builtin"
        )
        let options = list.menuOptions(selectedID: "")
        #expect(options.map(\.id) == ["", "builtin", "usb"])
        #expect(options[0].title == "System Default (MacBook Pro Microphone)")
        #expect(options.allSatisfy { $0.isConnected })

        let missing = list.menuOptions(selectedID: "gone")
        #expect(missing.map(\.id) == ["", "builtin", "usb", "gone"])
        #expect(missing.last?.isConnected == false)

        #expect(MicrophoneDeviceList.empty.menuOptions(selectedID: "").map(\.title) == ["System Default"])
    }

    @Test func coordinatorAsksOnlyForRealMicrophone() {
        let target = RecordingTarget.area(GlobalRect(x: 0, y: 0, width: 100, height: 100), displayID: CGMainDisplayID())
        var options = RecordingOptions.default
        options.microphone = .systemDefault
        let screen = RecordingRequest(target: target, options: options, source: .screen)
        #expect(RecordingCoordinator.needsMicrophoneAccess(screen))
        #expect(!RecordingCoordinator.needsMicrophoneAccess(RecordingRequest(target: target, options: options, source: .synthetic)))
        #expect(!RecordingCoordinator.needsMicrophoneAccess(RecordingRequest(target: target, options: options, format: .gif)))
        #expect(!RecordingCoordinator.needsMicrophoneAccess(RecordingRequest(target: target)))
        let stripped = RecordingCoordinator.withoutMicrophone(screen)
        #expect(stripped.options.microphone == nil)
        #expect(stripped.target == screen.target)
    }

    @Test func audioSettingsAccessRow() {
        #expect(AudioSettingsSection.showsAccessRow(microphoneEnabled: true, access: .denied))
        #expect(AudioSettingsSection.showsAccessRow(microphoneEnabled: true, access: .notDetermined))
        #expect(!AudioSettingsSection.showsAccessRow(microphoneEnabled: true, access: .authorized))
        #expect(!AudioSettingsSection.showsAccessRow(microphoneEnabled: false, access: .denied))
    }

    @Test func statsCarrySilentMicrophone() {
        #expect(!RecordingStats.zero.microphoneSilent)
        #expect(RecordingStats(microphoneLevel: 0, microphoneSilent: true).microphoneSilent)
        #expect(PermissionsService.Pane.microphone.rawValue == "Privacy_Microphone")
        #expect(PermissionsService.Pane.camera.rawValue == "Privacy_Camera")
        #expect(PermissionsService.Pane.inputMonitoring.rawValue == "Privacy_ListenEvent")
    }
}
