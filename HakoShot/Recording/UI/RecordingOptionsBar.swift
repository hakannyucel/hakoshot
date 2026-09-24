import AppKit
import HakoKit
import os
import SwiftUI

// Pre-record HUD (kayit-teknik-plan §4.2, R1.1; CleanShot report
// `cleanshot-recording-settings-ui.md` §2.2): two dark pills embedded in the
// `.recording` selection overlay.
//
//   Row 1: W × H fields · ratio menu · Fullscreen
//   Row 2: mic ⌄ · system audio · camera · clicks · keystrokes | options | ● Record ⌄
//
// Toggles write their `RecordingSettings` keys immediately (they are the
// persistent settings, plan §4.2). Return / double-click confirm with the
// format from `RecordFormatChoice.forConfirm(modifiers:)`; the Record button
// and the format menu set it explicitly. Read `selection` after
// `SelectionOverlayController.run(_:accessory:)` returns.

extension Log {
    nonisolated static let recordingHUD = Logger(subsystem: subsystem, category: "recording-hud")
}

// MARK: - Toggles

/// One on/off control of the HUD, bound to a `RecordingSettings` key.
enum RecordingHUDToggle: String, CaseIterable, Sendable {
    // Lower pill (plan §4.2).
    case microphone
    case systemAudio
    case camera
    case highlightClicks
    case showKeystrokes
    // Options menu.
    case showCursor
    case countdown
    case doNotDisturb
    case hideDesktopIcons

    static let pillToggles: [RecordingHUDToggle] = [.microphone, .systemAudio, .camera, .highlightClicks, .showKeystrokes]
    static let optionsMenuToggles: [RecordingHUDToggle] = [.showCursor, .countdown, .doNotDisturb, .hideDesktopIcons]

    var settingsKey: SettingsKey<Bool> {
        switch self {
        case .microphone: .recordingMicrophoneEnabled
        case .systemAudio: .recordingSystemAudio
        case .camera: .recordingCameraEnabled
        case .highlightClicks: .recordingHighlightClicks
        case .showKeystrokes: .recordingShowKeystrokes
        case .showCursor: .recordingShowCursor
        case .countdown: .recordingShowCountdown
        case .doNotDisturb: .recordingDoNotDisturb
        case .hideDesktopIcons: .recordingHideDesktopIcons
        }
    }

    /// Camera needs a connected camera (R4.I); without one it is shown
    /// dimmed and doesn't change the setting. Everything else is always
    /// available.
    nonisolated func isAvailable(hasCamera: Bool) -> Bool { self != .camera || hasCamera }

    var title: String {
        switch self {
        case .microphone: "Microphone"
        case .systemAudio: "System Audio"
        case .camera: "Camera"
        case .highlightClicks: "Highlight Clicks"
        case .showKeystrokes: "Show Keystrokes"
        case .showCursor: "Show Cursor"
        case .countdown: "Show Countdown"
        case .doNotDisturb: "Do Not Disturb"
        case .hideDesktopIcons: "Hide Desktop Icons"
        }
    }

    func symbol(isOn: Bool) -> String {
        switch self {
        case .microphone: isOn ? "mic.fill" : "mic.slash"
        case .systemAudio: isOn ? "speaker.wave.2.fill" : "speaker.slash"
        case .camera: isOn ? "video.fill" : "video.slash"
        case .highlightClicks: "cursorarrow.click.2"
        case .showKeystrokes: "command"
        case .showCursor: "cursorarrow"
        case .countdown: "timer"
        case .doNotDisturb: "moon.fill"
        case .hideDesktopIcons: "menubar.dock.rectangle"
        }
    }
}

// MARK: - Model

/// State of the pre-record HUD (SwiftUI observes it; `RecordingOptionsBar` drives it).
@Observable
final class RecordingHUDModel: SizeBarModel {
    enum Menu: Equatable {
        case ratio, microphone, camera, options, format
    }

    /// HUD ratio menu: HakoKit `RecordingAspectRatio.hudPresets` (5:4 included).
    static let ratioPresets: [AspectRatioPreset] = RecordingAspectRatio.hudPresets.map(AspectRatioPreset.init)

    var selectionSize: CGSize?
    var isWindowMode = false
    var ratio: AspectRatioPreset = .freeform
    var widthText = ""
    var heightText = ""
    var isEditingSize = false
    /// At most one dropdown is open.
    var openMenu: Menu?
    var showsRatioMenu: Bool { openMenu == .ratio }

    private(set) var toggles: [RecordingHUDToggle: Bool] = [:]
    /// `recordingMicrophoneDeviceID`; "" = System Default.
    private(set) var microphoneDeviceID = ""
    /// Microphone TCC state, re-read on `reload()` and after a request.
    private(set) var microphoneAccess: MediaAuthorization = .notDetermined
    /// `recordingCameraDeviceID`; "" = system default camera.
    private(set) var cameraDeviceID = ""
    private(set) var cameraShape: CameraShape = .squircle
    /// The camera was turned on but access is denied: the toggle went back
    /// off and the HUD shows "Open Settings" (R4.I).
    private(set) var showsCameraWarning = false
    /// "Show keystrokes" is on but Input Monitoring is denied (R5.I).
    private(set) var showsKeystrokeWarning = false

    @ObservationIgnored let settings: AppSettings
    /// Input devices for the mic menu (`MicrophoneDevices.shared`).
    @ObservationIgnored let microphones: MicrophoneDevices
    @ObservationIgnored private let readMicrophoneAccess: () -> MediaAuthorization
    @ObservationIgnored private let requestMicrophoneAccess: () async -> Bool
    /// Cameras for the camera menu (`CameraDevices.shared`).
    @ObservationIgnored let cameras: CameraDevices
    @ObservationIgnored private let readHasCamera: () -> Bool
    @ObservationIgnored private let requestCameraAccess: () async -> Bool
    @ObservationIgnored private let readInputMonitoring: () -> InputMonitoringPermission.Status
    @ObservationIgnored private let requestInputMonitoring: () -> Void

    init(
        settings: AppSettings = .shared,
        microphones: MicrophoneDevices = .shared,
        microphoneAccess: @escaping () -> MediaAuthorization = { MediaPermissions.microphone },
        requestMicrophoneAccess: @escaping () async -> Bool = { await MediaPermissions.requestMicrophone() },
        cameras: CameraDevices = .shared,
        hasCamera: (() -> Bool)? = nil,
        requestCameraAccess: @escaping () async -> Bool = { await CameraPermission.request() },
        inputMonitoring: @escaping () -> InputMonitoringPermission.Status = { InputMonitoringPermission.status },
        requestInputMonitoring: @escaping () -> Void = { InputMonitoringPermission.request() }
    ) {
        self.settings = settings
        self.microphones = microphones
        readMicrophoneAccess = microphoneAccess
        self.requestMicrophoneAccess = requestMicrophoneAccess
        self.cameras = cameras
        readHasCamera = hasCamera ?? { cameras.hasCamera }
        self.requestCameraAccess = requestCameraAccess
        readInputMonitoring = inputMonitoring
        self.requestInputMonitoring = requestInputMonitoring
        reload()
    }

    /// A camera is connected (the camera toggle and menu are usable).
    var hasCamera: Bool { readHasCamera() }

    func isAvailable(_ toggle: RecordingHUDToggle) -> Bool {
        toggle.isAvailable(hasCamera: hasCamera)
    }

    /// Re-reads every bound key (e.g. the Settings page changed one).
    func reload() {
        toggles = Dictionary(uniqueKeysWithValues: RecordingHUDToggle.allCases.map { ($0, settings.value(for: $0.settingsKey)) })
        microphoneDeviceID = settings.value(for: .recordingMicrophoneDeviceID)
        microphoneAccess = readMicrophoneAccess()
        cameraDeviceID = settings.value(for: .recordingCameraDeviceID)
        cameraShape = settings.value(for: .recordingCameraShape)
    }

    /// The camera menu rows: Default, then the connected cameras.
    var cameraOptions: [CameraSettingsSection.PickerOption] {
        CameraSettingsSection.pickerOptions(devices: cameras.list, selectedID: cameraDeviceID)
    }

    /// With the camera on, asks for access (the system prompt shows once).
    /// Denied → the toggle goes back off and the "Open Settings" row shows.
    func ensureCameraAccess() async {
        guard isOn(.camera) else { return }
        if await requestCameraAccess() {
            showsCameraWarning = false
            return
        }
        Log.recordingHUD.notice("camera access denied; camera turned off")
        set(.camera, false)
        showsCameraWarning = true
    }

    /// "Show keystrokes" just turned on: prompts for Input Monitoring once if
    /// it was never asked; shows "Open Settings" when it is denied. Off
    /// hides the warning. Never called during a recording.
    func checkKeystrokeAccess() {
        guard isOn(.showKeystrokes) else {
            showsKeystrokeWarning = false
            return
        }
        if readInputMonitoring() == .notDetermined { requestInputMonitoring() }
        showsKeystrokeWarning = readInputMonitoring() == .denied
    }

    /// "" = default camera. Picking a camera also turns it on.
    func selectCamera(deviceID: String) {
        cameraDeviceID = deviceID
        settings.set(deviceID, for: .recordingCameraDeviceID)
        set(.camera, true)
    }

    func selectCameraShape(_ shape: CameraShape) {
        cameraShape = shape
        settings.set(shape, for: .recordingCameraShape)
    }

    /// The mic menu rows: System Default, then the connected devices.
    var microphoneOptions: [MicrophoneMenuOption] {
        microphones.list.menuOptions(selectedID: microphoneDeviceID)
    }

    /// Mic on but access denied: the HUD shows "Open Settings" (plan §6 R2).
    var showsMicrophoneWarning: Bool {
        isOn(.microphone) && microphoneAccess.needsSystemSettings
    }

    /// With the microphone on, asks for access if it was never asked (the
    /// system prompt shows once); afterwards re-reads the state.
    func ensureMicrophoneAccess() async {
        guard isOn(.microphone) else { return }
        if readMicrophoneAccess() == .notDetermined {
            _ = await requestMicrophoneAccess()
        }
        microphoneAccess = readMicrophoneAccess()
    }

    func isOn(_ toggle: RecordingHUDToggle) -> Bool {
        toggles[toggle] ?? settings.value(for: toggle.settingsKey)
    }

    /// Writes the setting; unavailable toggles (camera without a camera) are ignored.
    func set(_ toggle: RecordingHUDToggle, _ isOn: Bool) {
        guard isAvailable(toggle) else { return }
        toggles[toggle] = isOn
        settings.set(isOn, for: toggle.settingsKey)
    }

    func toggle(_ toggle: RecordingHUDToggle) {
        set(toggle, !isOn(toggle))
    }

    /// "" = System Default. Picking a device also turns the microphone on.
    func selectMicrophone(deviceID: String) {
        microphoneDeviceID = deviceID
        settings.set(deviceID, for: .recordingMicrophoneDeviceID)
        set(.microphone, true)
    }

    func updateSizeTexts() {
        guard !isEditingSize else { return }
        widthText = selectionSize.map { "\(Int($0.width.rounded()))" } ?? ""
        heightText = selectionSize.map { "\(Int($0.height.rounded()))" } ?? ""
    }
}

extension AspectRatioPreset {
    /// HakoKit ratio → size bar preset (freeform stays freeform).
    nonisolated init(_ ratio: RecordingAspectRatio) {
        self = ratio.isFreeform ? .freeform : .fixed(width: ratio.width, height: ratio.height)
    }
}

// MARK: - Accessory

/// The HUD as an `OverlayAccessory` for `OverlayConfig(mode: .recording)`.
final class RecordingOptionsBar: OverlayAccessory {
    let model: RecordingHUDModel
    let view: NSView
    /// Bottom-center of the display, like the All-In-One bar (plan §4.2
    /// "alt-ortada", `Tokens.Recording.hudBottomInset`): the dropdowns grow
    /// upward without moving the pills.
    var placement: OverlayAccessoryPlacement { .bottomCenter }

    /// Format / profile / overrides; `nil` until the overlay finished, and
    /// after a cancel.
    private(set) var selection: RecordingHUDSelection?
    /// The selection when the session ended (for `recordingLastRect`).
    private(set) var finalSelection: GlobalRect?

    private weak var host: (any OverlayAccessoryHost)?
    /// Set by the Record button / format menu right before confirming.
    private var pendingChoice: RecordFormatChoice?

    init(settings: AppSettings = .shared) {
        let model = RecordingHUDModel(settings: settings)
        self.model = model
        let actions = RecordingOptionsBarActions()
        let hosting = RecordingHUDHostingView(rootView: RecordingOptionsBarView(model: model, actions: actions))
        hosting.frame.size = hosting.fittingSize
        view = hosting
        actions.bar = self
    }

    // MARK: OverlayAccessory

    func overlayDidStart(_ host: any OverlayAccessoryHost) {
        self.host = host
        model.reload()
        model.isWindowMode = host.isWindowMode
        model.selectionSize = host.selection?.size
        model.updateSizeTexts()
    }

    func overlay(_ host: any OverlayAccessoryHost, selectionDidChange rect: GlobalRect?) {
        model.selectionSize = rect?.size
        model.updateSizeTexts()
    }

    func overlay(_ host: any OverlayAccessoryHost, windowModeDidChange isWindowMode: Bool) {
        model.isWindowMode = isWindowMode
        if isWindowMode, model.openMenu == .ratio { closeMenu() }
    }

    func overlay(_ host: any OverlayAccessoryHost, willFinishWith outcome: SelectionOutcome) {
        finalSelection = host.selection
        switch outcome {
        case .cancelled:
            selection = nil
        case .area, .frozenArea, .window, .fullscreen:
            let choice = pendingChoice ?? RecordFormatChoice.forConfirm(modifiers: Self.confirmModifiers())
            selection = RecordingHUDSelection(choice: choice)
            Log.recordingHUD.notice("finishing with \(choice.rawValue, privacy: .public)")
        }
        pendingChoice = nil
    }

    /// Modifiers of the event that confirmed (Return key / double-click).
    private static func confirmModifiers() -> NSEvent.ModifierFlags {
        NSApp.currentEvent?.modifierFlags ?? NSEvent.modifierFlags
    }

    // MARK: Actions (also used by DEBUG automation)

    /// Record button / format menu row: confirm the selection with `choice`.
    func record(_ choice: RecordFormatChoice) {
        closeMenu()
        guard let host, host.selection != nil, !host.isWindowMode else {
            NSSound.beep()
            return
        }
        pendingChoice = choice
        host.confirmSelection()
    }

    func fullscreenTapped() {
        guard let host else { return }
        closeMenu()
        let displayID = host.selectionDisplayID ?? host.cursorDisplayID ?? CGMainDisplayID()
        host.finish(.fullscreen(displayID: displayID))
    }

    func toggle(_ toggle: RecordingHUDToggle) {
        guard model.isAvailable(toggle) else {
            NSSound.beep()
            return
        }
        model.toggle(toggle)
        Log.recordingHUD.notice("\(toggle.rawValue, privacy: .public) -> \(self.model.isOn(toggle))")
        switch toggle {
        case .microphone: checkMicrophoneAccess()
        case .camera: checkCameraAccess()
        case .showKeystrokes: model.checkKeystrokeAccess()
        default: break
        }
        relayoutSoon()
    }

    func selectCamera(deviceID: String) {
        model.selectCamera(deviceID: deviceID)
        closeMenu()
        checkCameraAccess()
    }

    func selectCameraShape(_ shape: CameraShape) {
        model.selectCameraShape(shape)
        closeMenu()
    }

    /// Camera just turned on: request access; denied → back off + warning row.
    private func checkCameraAccess() {
        guard model.isOn(.camera) else { return }
        Task { [weak self] in
            await self?.model.ensureCameraAccess()
            self?.relayoutSoon()
        }
    }

    /// Warning row "Open Settings" for the camera / keystrokes (Input Monitoring).
    func openSettings(_ pane: PermissionsService.Pane) {
        host?.cancel()
        PermissionsService.openSystemSettings(pane)
    }

    func selectMicrophone(deviceID: String) {
        model.selectMicrophone(deviceID: deviceID)
        closeMenu()
        checkMicrophoneAccess()
    }

    /// Mic just turned on: prompt for access once; the warning row appears if denied.
    private func checkMicrophoneAccess() {
        guard model.isOn(.microphone) else { return }
        Task { [weak self] in
            await self?.model.ensureMicrophoneAccess()
            self?.relayoutSoon()
        }
    }

    /// Warning row "Open Settings": ends the selection (the overlay would
    /// cover System Settings) and opens Privacy › Microphone.
    func openMicrophoneSettings() {
        host?.cancel()
        PermissionsService.openSystemSettings(.microphone)
    }

    /// Opens `menu`, or closes it when it is already open.
    func toggleMenu(_ menu: RecordingHUDModel.Menu) {
        model.openMenu = model.openMenu == menu ? nil : menu
        if model.openMenu == .microphone { model.microphones.refresh() }
        if model.openMenu == .camera { model.cameras.refresh() }
        relayoutSoon()
    }

    func closeMenu() {
        guard model.openMenu != nil else { return }
        model.openMenu = nil
        relayoutSoon()
    }

    /// A size field was submitted; `editedWidth` tells which side was typed.
    func submitSize(editedWidth: Bool) {
        defer { returnFocusToOverlay() }
        guard let host else { return }
        guard let size = SizeBarMath.submittedSize(
            widthText: model.widthText, heightText: model.heightText,
            current: model.selectionSize, ratio: model.ratio.ratio, editedWidth: editedWidth
        ) else {
            model.updateSizeTexts()
            return
        }
        Log.recordingHUD.notice("size field -> \(Int(size.width))x\(Int(size.height)) pt")
        host.setSelectionSize(size)
        model.updateSizeTexts()
    }

    func selectRatio(_ preset: AspectRatioPreset) {
        var preset = preset
        if case .custom = preset {
            guard let size = model.selectionSize, size.width > 0, size.height > 0 else {
                NSSound.beep()
                return
            }
            preset = .custom(size.width / size.height)
        }
        model.ratio = preset
        host?.aspectRatio = preset.ratio
        closeMenu()
    }

    // MARK: Layout

    /// A dropdown changes the view's size between overlay renders: grow or
    /// shrink around the bottom-center now (same as `AllInOneBar`).
    private func relayoutSoon() {
        Task { @MainActor [weak self] in
            await Task.yield()
            self?.relayout()
        }
    }

    private func relayout() {
        view.layoutSubtreeIfNeeded()
        let size = view.fittingSize
        guard size.width > 0, size.height > 0 else { return }
        var frame = view.frame
        frame.origin.x = frame.midX - size.width / 2
        frame.size = size
        view.frame = frame.integral
    }

    private func returnFocusToOverlay() {
        guard let window = view.window else { return }
        window.makeFirstResponder(view.superview)
    }
}

/// Indirection so the SwiftUI view doesn't retain the bar.
final class RecordingOptionsBarActions {
    weak var bar: RecordingOptionsBar?
}

/// Takes the first click even when its panel isn't key (other display).
private final class RecordingHUDHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

// MARK: - View

struct RecordingOptionsBarView: View {
    let model: RecordingHUDModel
    let actions: RecordingOptionsBarActions

    var body: some View {
        VStack(alignment: menuAlignment, spacing: Tokens.Recording.hudPillGap) {
            if let menu = model.openMenu {
                menuView(menu)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
            if model.showsMicrophoneWarning {
                HUDAccessWarning(symbol: "mic.slash.fill", text: "Microphone access is off") {
                    actions.bar?.openMicrophoneSettings()
                }
                .transition(.opacity)
            }
            if model.showsCameraWarning {
                HUDAccessWarning(symbol: "video.slash.fill", text: "Camera access is off") {
                    actions.bar?.openSettings(.camera)
                }
                .transition(.opacity)
            }
            if model.showsKeystrokeWarning {
                HUDAccessWarning(symbol: "keyboard", text: "Keystrokes need Input Monitoring") {
                    actions.bar?.openSettings(.inputMonitoring)
                }
                .transition(.opacity)
            }
            VStack(spacing: Tokens.Recording.hudPillGap) {
                sizePill
                controlsPill
            }
        }
        .padding(Tokens.Recording.hudShadowMargin)
        .animation(DSAnimation.popoverIn, value: model.openMenu)
        .animation(DSAnimation.popoverIn, value: model.showsMicrophoneWarning)
        .animation(DSAnimation.popoverIn, value: model.showsCameraWarning)
        .animation(DSAnimation.popoverIn, value: model.showsKeystrokeWarning)
        .fixedSize()
    }

    /// Each dropdown sits over the control that opened it.
    private var menuAlignment: HorizontalAlignment {
        switch model.openMenu {
        case .microphone, .camera: .leading
        case .format, .options: .trailing
        case .ratio, nil: .center
        }
    }

    @ViewBuilder
    private func menuView(_ menu: RecordingHUDModel.Menu) -> some View {
        switch menu {
        case .ratio:
            SizeBarRatioMenu(model: model, presets: RecordingHUDModel.ratioPresets) { actions.bar?.selectRatio($0) }
        case .format:
            RecordFormatMenu { actions.bar?.record($0) }
        case .microphone:
            MicrophoneMenu(model: model, actions: actions)
        case .camera:
            CameraMenu(model: model, actions: actions)
        case .options:
            OptionsMenu(model: model, actions: actions)
        }
    }

    // MARK: Row 1

    private var sizePill: some View {
        HStack(spacing: Tokens.Spacing.s) {
            SizeBarFields(model: model) { actions.bar?.submitSize(editedWidth: $0) }
            SizeBarDivider(height: Tokens.Recording.hudDividerHeight)
            SizeBarRatioButton(model: model) { actions.bar?.toggleMenu(.ratio) }
                .disabled(model.isWindowMode)
            SizeBarDivider(height: Tokens.Recording.hudDividerHeight)
            HUDToggleButton(symbol: "display", isOn: false, help: "Record the whole display") {
                actions.bar?.fullscreenTapped()
            }
        }
        .padding(.horizontal, Tokens.Recording.hudPillPaddingH)
        .padding(.vertical, Tokens.Recording.hudPillPaddingV)
        .frame(height: Tokens.Recording.hudPillHeight)
        .hudPanel(cornerRadius: Tokens.Recording.hudPillRadius)
    }

    // MARK: Row 2

    private var controlsPill: some View {
        HStack(spacing: Tokens.Recording.hudToggleGap) {
            toggleButton(.microphone)
            HUDChevronButton(isOpen: model.openMenu == .microphone, help: "Microphone") {
                actions.bar?.toggleMenu(.microphone)
            }
            toggleButton(.systemAudio)
            toggleButton(.camera)
            if model.hasCamera {
                HUDChevronButton(isOpen: model.openMenu == .camera, help: "Camera") {
                    actions.bar?.toggleMenu(.camera)
                }
            }
            toggleButton(.highlightClicks)
            toggleButton(.showKeystrokes)
            SizeBarDivider(height: Tokens.Recording.hudDividerHeight)
            HUDToggleButton(symbol: "slider.vertical.3", isOn: model.openMenu == .options, help: "Options") {
                actions.bar?.toggleMenu(.options)
            }
            SizeBarDivider(height: Tokens.Recording.hudDividerHeight)
            RecordSplitButton(
                isEnabled: model.selectionSize != nil && !model.isWindowMode,
                isMenuOpen: model.openMenu == .format,
                record: { actions.bar?.record(.video) },
                openMenu: { actions.bar?.toggleMenu(.format) }
            )
        }
        .padding(.horizontal, Tokens.Recording.hudPillPaddingH)
        .padding(.vertical, Tokens.Recording.hudPillPaddingV)
        .frame(height: Tokens.Recording.hudPillHeight)
        .hudPanel(cornerRadius: Tokens.Recording.hudPillRadius)
    }

    private func toggleButton(_ toggle: RecordingHUDToggle) -> some View {
        let isOn = model.isOn(toggle)
        let isAvailable = model.isAvailable(toggle)
        return HUDToggleButton(
            symbol: toggle.symbol(isOn: isOn),
            isOn: isOn,
            isAvailable: isAvailable,
            help: isAvailable ? toggle.title : "\(toggle.title) (no camera connected)"
        ) {
            actions.bar?.toggle(toggle)
        }
        .accessibilityLabel(toggle.title)
    }
}

// MARK: - Controls

/// 32 pt square icon toggle: highlighted when on, dim when off.
private struct HUDToggleButton: View {
    let symbol: String
    let isOn: Bool
    var isAvailable = true
    let help: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: Tokens.Recording.hudToggleGlyphSize, weight: .medium))
                .foregroundStyle(Color(nsColor: isOn ? Tokens.Palette.hudTextPrimary : Tokens.Palette.hudTextSecondary))
                .frame(width: Tokens.Recording.hudToggleSize, height: Tokens.Recording.hudToggleSize)
                .background {
                    RoundedRectangle(cornerRadius: Tokens.Recording.hudToggleRadius, style: .continuous)
                        .fill(fill)
                }
                .contentShape(RoundedRectangle(cornerRadius: Tokens.Recording.hudToggleRadius, style: .continuous))
        }
        .buttonStyle(.plain)
        .opacity(isAvailable ? 1 : Tokens.Recording.hudUnavailableOpacity)
        .onHover { hovering = $0 }
        .animation(DSAnimation.hoverControls, value: hovering)
        .help(help)
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }

    private var fill: Color {
        if isOn && isAvailable { return Color(nsColor: Tokens.Palette.hudItemHighlight) }
        return hovering && isAvailable ? Tokens.AllInOne.hoverFill : .clear
    }
}

/// Narrow ⌄ button that opens a device menu.
private struct HUDChevronButton: View {
    let isOpen: Bool
    let help: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "chevron.up")
                .font(.system(size: Tokens.Recording.hudChevronGlyphSize, weight: .bold))
                .rotationEffect(.degrees(isOpen ? 180 : 0))
                .foregroundStyle(Color(nsColor: Tokens.Palette.hudTextSecondary))
                .frame(width: Tokens.Recording.hudChevronWidth, height: Tokens.Recording.hudToggleSize)
                .background {
                    RoundedRectangle(cornerRadius: Tokens.Recording.hudToggleRadius, style: .continuous)
                        .fill(hovering || isOpen ? Tokens.AllInOne.hoverFill : .clear)
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help)
    }
}

/// Red "● Record" pill with a ⌄ segment for the format menu.
private struct RecordSplitButton: View {
    let isEnabled: Bool
    let isMenuOpen: Bool
    let record: () -> Void
    let openMenu: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            Button(action: record) {
                HStack(spacing: Tokens.Spacing.pillIconGap) {
                    Circle()
                        .fill(Color.white)
                        .frame(width: Tokens.Recording.hudRecordDotDiameter, height: Tokens.Recording.hudRecordDotDiameter)
                    Text("Record")
                        .font(Tokens.Typography.pillLabel)
                        .lineLimit(1)
                }
                .padding(.leading, Tokens.Recording.hudRecordButtonPaddingH)
                .padding(.trailing, Tokens.Spacing.s)
                .frame(height: Tokens.Recording.hudRecordButtonHeight)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!isEnabled)
            .help("Record Video (Return)")

            Rectangle()
                .fill(Color.white.opacity(Tokens.Recording.hudRecordSegmentDividerOpacity))
                .frame(width: Tokens.Stroke.hairline, height: Tokens.Recording.hudDividerHeight)

            Button(action: openMenu) {
                Image(systemName: "chevron.up")
                    .font(.system(size: Tokens.Recording.hudChevronGlyphSize, weight: .bold))
                    .rotationEffect(.degrees(isMenuOpen ? 180 : 0))
                    .frame(width: Tokens.Recording.hudRecordChevronWidth, height: Tokens.Recording.hudRecordButtonHeight)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Record GIF or in Studio Mode")
        }
        .foregroundStyle(Color.white)
        .background(Capsule().fill(Color(nsColor: Tokens.Recording.recordRed)))
        .opacity(isEnabled ? 1 : Tokens.Recording.hudUnavailableOpacity)
    }
}

// MARK: - Menus

/// Microphone on/off + input devices (System Default first; a saved device
/// that is unplugged stays listed, disabled).
private struct MicrophoneMenu: View {
    let model: RecordingHUDModel
    let actions: RecordingOptionsBarActions

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HUDMenuRow(title: "Record Microphone", checked: model.isOn(.microphone)) {
                actions.bar?.toggle(.microphone)
            }
            HUDMenuSeparator()
            ForEach(model.microphoneOptions) { option in
                HUDMenuRow(
                    title: option.title,
                    checked: model.microphoneDeviceID == option.id,
                    isEnabled: option.isConnected,
                    icon: { EmptyView() }
                ) {
                    actions.bar?.selectMicrophone(deviceID: option.id)
                }
            }
        }
        .padding(Tokens.Recording.hudMenuPadding)
        .frame(width: Tokens.Recording.hudMicrophoneMenuWidth)
        .hudPanel(cornerRadius: Tokens.AllInOne.menuRadius, shadow: .toast)
    }
}

/// Camera on/off, the cameras (Default first; a saved camera that is
/// unplugged stays listed) and the bubble shape (R4.I).
private struct CameraMenu: View {
    let model: RecordingHUDModel
    let actions: RecordingOptionsBarActions

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HUDMenuRow(title: "Show Camera", checked: model.isOn(.camera)) {
                actions.bar?.toggle(.camera)
            }
            HUDMenuSeparator()
            ForEach(model.cameraOptions, id: \.id) { option in
                HUDMenuRow(
                    title: option.title,
                    checked: model.cameraDeviceID == option.id,
                    isEnabled: option.id.isEmpty || model.cameras.devices.contains { $0.id == option.id },
                    icon: { EmptyView() }
                ) {
                    actions.bar?.selectCamera(deviceID: option.id)
                }
            }
            HUDMenuSeparator()
            ForEach(CameraShape.allCases, id: \.self) { shape in
                HUDMenuRow(title: shape.optionTitle, checked: model.cameraShape == shape, icon: { EmptyView() }) {
                    actions.bar?.selectCameraShape(shape)
                }
            }
        }
        .padding(Tokens.Recording.hudMenuPadding)
        .frame(width: Tokens.Recording.hudMicrophoneMenuWidth)
        .hudPanel(cornerRadius: Tokens.AllInOne.menuRadius, shadow: .toast)
    }
}

/// "<Thing> access is off" + Open Settings, above the pills while a toggle
/// is on and its access was denied (plan §6 R2 acceptance 3, R4.I, R5.I).
private struct HUDAccessWarning: View {
    let symbol: String
    let text: String
    let openSettings: () -> Void

    var body: some View {
        HStack(spacing: Tokens.Spacing.s) {
            Image(systemName: symbol)
                .font(.system(size: Tokens.Recording.hudMenuIconSize, weight: .medium))
                .foregroundStyle(Color(nsColor: .systemYellow))
            Text(text)
                .font(Tokens.Typography.rowLabel)
                .foregroundStyle(Color(nsColor: Tokens.Palette.hudTextPrimary))
                .lineLimit(1)
            Button("Open Settings", action: openSettings)
                .buttonStyle(.plain)
                .font(Tokens.Typography.rowLabel.weight(.semibold))
                .foregroundStyle(Color(nsColor: Tokens.Palette.hudTextPrimary))
                .padding(.horizontal, Tokens.Spacing.s)
                .frame(height: Tokens.Recording.hudToggleSize - Tokens.Spacing.s)
                .background(Capsule().fill(Color(nsColor: Tokens.Palette.hudItemHighlight)))
        }
        .padding(.horizontal, Tokens.Recording.hudPillPaddingH)
        .frame(height: Tokens.Recording.hudPillHeight)
        .hudPanel(cornerRadius: Tokens.Recording.hudPillRadius)
        .accessibilityElement(children: .combine)
    }
}

/// Cursor, countdown, Do Not Disturb, desktop icons.
private struct OptionsMenu: View {
    let model: RecordingHUDModel
    let actions: RecordingOptionsBarActions

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(RecordingHUDToggle.optionsMenuToggles, id: \.self) { toggle in
                HUDMenuRow(title: toggle.title, checked: model.isOn(toggle)) {
                    Image(systemName: toggle.symbol(isOn: true))
                        .font(.system(size: Tokens.Recording.hudMenuIconSize, weight: .medium))
                        .frame(width: Tokens.Recording.hudMenuIconWidth)
                } action: {
                    actions.bar?.toggle(toggle)
                }
            }
        }
        .padding(Tokens.Recording.hudMenuPadding)
        .frame(width: Tokens.Recording.hudOptionsMenuWidth)
        .hudPanel(cornerRadius: Tokens.AllInOne.menuRadius, shadow: .toast)
    }
}
