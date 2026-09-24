import os
import AppKit
import Carbon.HIToolbox
import SwiftUI

/// Onboarding steps (M7, plan §2): welcome → Screen Recording → Accessibility
/// (optional) → recording permissions (info only, R7.4) → macOS screenshot
/// shortcuts → launch at login → done.
enum OnboardingStep: Int, CaseIterable, Identifiable {
    case welcome, screenRecording, accessibility, recordingPermissions, shortcuts, launchAtLogin, done

    var id: Int { rawValue }
}

/// First-launch window; also shown when Screen Recording is missing (then it
/// opens on that step) and from Settings › About.
final class OnboardingWindowController: NSWindowController, NSWindowDelegate {
    private let activationPolicy: ActivationPolicyController
    private let model: OnboardingModel
    var onClose: (() -> Void)?

    init(
        permissions: PermissionsService,
        activationPolicy: ActivationPolicyController,
        startStep: OnboardingStep = .welcome
    ) {
        self.activationPolicy = activationPolicy
        model = OnboardingModel(permissions: permissions, step: startStep)
        let size = Tokens.Onboarding.windowSize
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isReleasedWhenClosed = false
        window.isMovableByWindowBackground = true
        window.title = "Welcome to HakoShot"
        super.init(window: window)
        window.delegate = self
        let root = OnboardingView(model: model) { [weak self] in self?.close() }
        window.contentViewController = NSHostingController(rootView: root)
        window.setContentSize(size)
        window.center()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func present(step: OnboardingStep? = nil) {
        if let step { model.step = step }
        activationPolicy.acquire(self)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    func windowWillClose(_ notification: Notification) {
        activationPolicy.release(self)
        onClose?()
    }

    #if DEBUG
    /// Debug snapshots: jump to a step without user input.
    func debugShow(step: OnboardingStep) { model.step = step }
    #endif
}

/// Step state plus the live values the steps show (polled while visible).
@Observable
final class OnboardingModel {
    let permissions: PermissionsService
    /// Shared with Settings › General (`Settings/LaunchAtLogin.swift`).
    let loginItem: LaunchAtLogin
    var step: OnboardingStep
    /// macOS screenshot shortcuts (symbolic hotkeys 28/29/30/31/184) as read last.
    private(set) var systemShortcuts: [SystemScreenshotShortcut] = []
    /// Recording permissions as read last (status reads only; never prompts).
    private(set) var microphoneStatus: MediaAuthorization = .notDetermined
    private(set) var cameraStatus: MediaAuthorization = .notDetermined
    private(set) var inputMonitoringStatus: InputMonitoringPermission.Status = .notDetermined

    init(permissions: PermissionsService, loginItem: LaunchAtLogin = LaunchAtLogin(), step: OnboardingStep) {
        self.permissions = permissions
        self.loginItem = loginItem
        self.step = step
        refresh()
    }

    func refresh() {
        permissions.refresh()
        loginItem.refresh()
        let shortcuts = ShortcutConflictDetector.systemScreenshotShortcuts(
            symbolicHotKeys: ShortcutConflictDetector.readSymbolicHotKeys()
        )
        if shortcuts != systemShortcuts { systemShortcuts = shortcuts }
        // Status reads only: the prompts come when a feature is first used (plan §1.8).
        let microphone = MediaPermissions.microphone
        if microphone != microphoneStatus { microphoneStatus = microphone }
        let camera = CameraPermission.status
        if camera != cameraStatus { cameraStatus = camera }
        let inputMonitoring = InputMonitoringPermission.status
        if inputMonitoring != inputMonitoringStatus { inputMonitoringStatus = inputMonitoring }
    }

    var enabledSystemShortcutCount: Int { systemShortcuts.filter(\.isEnabled).count }

    var isFirst: Bool { step == OnboardingStep.allCases.first }
    var isLast: Bool { step == OnboardingStep.allCases.last }

    func next() {
        guard let next = OnboardingStep(rawValue: step.rawValue + 1) else { return }
        step = next
    }

    func back() {
        guard let previous = OnboardingStep(rawValue: step.rawValue - 1) else { return }
        step = previous
    }
}

struct OnboardingView: View {
    @Bindable var model: OnboardingModel
    let onDone: () -> Void

    private var permissions: PermissionsService { model.permissions }

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                stepContent
                    .id(model.step)
                    .transition(.opacity.combined(with: .offset(x: 0, y: Tokens.Spacing.s)))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.horizontal, Tokens.Onboarding.contentPaddingH)
            .padding(.top, Tokens.Onboarding.contentPaddingTop)

            footer
        }
        .frame(width: Tokens.Onboarding.windowSize.width, height: Tokens.Onboarding.windowSize.height)
        .animation(DSAnimation.respectingReduceMotion(DSAnimation.overlayFadeIn), value: model.step)
        .task {
            // Poll so statuses flip as soon as the user changes them in System Settings.
            while !Task.isCancelled {
                model.refresh()
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    // MARK: Steps

    @ViewBuilder
    private var stepContent: some View {
        switch model.step {
        case .welcome: welcome
        case .screenRecording: screenRecording
        case .accessibility: accessibility
        case .recordingPermissions: recordingPermissions
        case .shortcuts: shortcuts
        case .launchAtLogin: launchAtLogin
        case .done: done
        }
    }

    private var welcome: some View {
        VStack(spacing: Tokens.Spacing.l) {
            Spacer(minLength: 0)
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .interpolation(.high)
                .frame(width: Tokens.Onboarding.heroIcon, height: Tokens.Onboarding.heroIcon)
            Text("Welcome to HakoShot")
                .font(Tokens.Typography.settingsTitle)
            Text("Area, window, fullscreen, scrolling and text captures from the menu bar, with Quick Access, pins, history and an annotation editor.")
                .font(Tokens.Typography.rowLabel)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Text("A few permissions and settings first. It takes a minute.")
                .font(Tokens.Typography.rowLabel)
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
    }

    private var screenRecording: some View {
        StepLayout(
            symbol: "rectangle.dashed.badge.record",
            title: "Screen Recording",
            message: "HakoShot needs Screen Recording access to capture your screen. Nothing leaves your Mac."
        ) {
            PermissionCard(
                title: "Screen Recording",
                detail: permissions.screenRecordingGranted ? "Granted" : "Required for every capture",
                granted: permissions.screenRecordingGranted,
                required: true,
                grant: { permissions.requestScreenRecording() },
                openSettings: { permissions.openSystemSettings(.screenRecording) }
            )
            if !permissions.screenRecordingGranted {
                Note(text: "After you turn it on in System Settings, macOS may ask you to quit and reopen HakoShot.")
            }
        }
    }

    private var accessibility: some View {
        StepLayout(
            symbol: "arrow.up.and.down.text.horizontal",
            title: "Accessibility (optional)",
            message: "Scrolling Capture can scroll the page for you. Sending those scroll events needs Accessibility access. Without it you scroll by hand."
        ) {
            PermissionCard(
                title: "Accessibility",
                detail: permissions.accessibilityGranted ? "Granted" : "Only for auto-scroll",
                granted: permissions.accessibilityGranted,
                required: false,
                grant: {
                    permissions.requestAccessibility()
                    permissions.requestPostEvent()
                },
                openSettings: { permissions.openSystemSettings(.accessibility) }
            )
            if !permissions.accessibilityGranted {
                Note(text: "You can skip this and grant it later from Settings › About.")
            }
        }
    }

    /// Information only (R7.4): each permission is requested the first time
    /// its feature is turned on, never from here.
    private var recordingPermissions: some View {
        StepLayout(
            symbol: "record.circle",
            title: "Screen recording extras",
            message: "Recording can also use these. Nothing is asked now: macOS asks the first time you turn each one on."
        ) {
            VStack(spacing: 0) {
                RecordingPermissionRow(
                    symbol: "mic",
                    title: "Microphone",
                    detail: "Record your voice with a video",
                    status: RecordingPermissionRow.Status(model.microphoneStatus),
                    openSettings: { permissions.openMicrophoneSettings() }
                )
                rowDivider
                RecordingPermissionRow(
                    symbol: "video",
                    title: "Camera",
                    detail: "Show your webcam in a bubble",
                    status: RecordingPermissionRow.Status(model.cameraStatus),
                    openSettings: { CameraPermission.openSystemSettings() }
                )
                rowDivider
                RecordingPermissionRow(
                    symbol: "keyboard",
                    title: "Input Monitoring",
                    detail: "Show the keys you press in a recording",
                    status: RecordingPermissionRow.Status(model.inputMonitoringStatus),
                    openSettings: { InputMonitoringPermission.openSystemSettings() }
                )
            }
            .background(cardBackground)
            Note(text: "All three are optional. Screenshots and plain screen recordings work without them.")
        }
    }

    private var rowDivider: some View {
        Rectangle()
            .fill(Color.dsDivider)
            .frame(height: Tokens.Stroke.hairline)
            .padding(.leading, Tokens.Spacing.settingsRowH)
    }

    private var shortcuts: some View {
        StepLayout(
            symbol: "command",
            title: "Screenshot shortcuts",
            message: "HakoShot uses ⇧⌘3, ⇧⌘4 and ⇧⌘5 like the built-in tool. macOS handles its own shortcuts first, so turn them off in Keyboard Shortcuts › Screenshots."
        ) {
            VStack(spacing: 0) {
                ForEach(Array(model.systemShortcuts.enumerated()), id: \.element.id) { index, shortcut in
                    if index > 0 {
                        Rectangle()
                            .fill(Color.dsDivider)
                            .frame(height: Tokens.Stroke.hairline)
                            .padding(.leading, Tokens.Spacing.settingsRowH)
                    }
                    SystemShortcutRow(shortcut: shortcut)
                }
            }
            .background(cardBackground)

            HStack(spacing: Tokens.Spacing.s) {
                Image(systemName: model.enabledSystemShortcutCount == 0 ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(model.enabledSystemShortcutCount == 0 ? Color.green : Color.orange)
                Text(model.enabledSystemShortcutCount == 0
                     ? "All set: HakoShot owns the screenshot shortcuts."
                     : "\(model.enabledSystemShortcutCount) macOS shortcut\(model.enabledSystemShortcutCount == 1 ? " is" : "s are") still on.")
                    .font(Tokens.Typography.rowDescription)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Open Keyboard Settings") {
                    if let url = ShortcutConflictDetector.keyboardSettingsURL { NSWorkspace.shared.open(url) }
                }
                .buttonStyle(PillButtonStyle(style: .neutral))
            }
        }
    }

    private var launchAtLogin: some View {
        StepLayout(
            symbol: "power",
            title: "Launch at login",
            message: "Keep HakoShot in the menu bar so the shortcuts work right after you log in."
        ) {
            HStack(spacing: Tokens.Spacing.m) {
                VStack(alignment: .leading, spacing: Tokens.Spacing.settingsRowTextGap) {
                    Text("Launch HakoShot at login").font(Tokens.Typography.rowLabel)
                    if model.loginItem.requiresApproval {
                        Text("Allow HakoShot in System Settings › General › Login Items.")
                            .font(Tokens.Typography.rowDescription)
                            .foregroundStyle(.secondary)
                    } else if let error = model.loginItem.lastError {
                        Text(error)
                            .font(Tokens.Typography.rowDescription)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if model.loginItem.requiresApproval {
                    Button("Open Login Items") { model.loginItem.openLoginItemsSettings() }
                        .buttonStyle(PillButtonStyle(style: .neutral))
                }
                Toggle("Launch at login", isOn: Binding(
                    get: { model.loginItem.isEnabled },
                    set: { model.loginItem.setEnabled($0) }
                ))
                .toggleStyle(.switch)
                .labelsHidden()
            }
            .padding(.vertical, Tokens.Spacing.settingsRowV)
            .padding(.horizontal, Tokens.Spacing.settingsRowH)
            .background(cardBackground)
        }
    }

    private var done: some View {
        VStack(spacing: Tokens.Spacing.l) {
            Spacer(minLength: 0)
            Image(systemName: permissions.screenRecordingGranted ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .font(.system(size: Tokens.Onboarding.doneSymbol, weight: .regular))
                .foregroundStyle(permissions.screenRecordingGranted ? Color.green : Color.orange)
            Text(permissions.screenRecordingGranted ? "You're all set" : "Almost there")
                .font(Tokens.Typography.settingsTitle)
            Text(permissions.screenRecordingGranted
                 ? "HakoShot lives in the menu bar. Press ⇧⌘4 to capture an area or ⇧⌘1 for All-In-One."
                 : "Captures stay off until Screen Recording is granted. HakoShot shows this window again until then.")
                .font(Tokens.Typography.rowLabel)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }

    // MARK: Footer

    private var footer: some View {
        ZStack {
            StepDots(current: model.step)
            HStack(spacing: Tokens.Spacing.s) {
                if !model.isFirst && !model.isLast {
                    Button("Back") { model.back() }
                        .buttonStyle(PillButtonStyle(style: .neutral))
                }
                Spacer()
                if model.isLast {
                    Button("Done", action: onDone)
                        .buttonStyle(PillButtonStyle(style: .primary))
                        .keyboardShortcut(.defaultAction)
                } else {
                    Button(continueTitle) { model.next() }
                        .buttonStyle(PillButtonStyle(style: .primary))
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(.horizontal, Tokens.Onboarding.contentPaddingH)
        .padding(.vertical, Tokens.Spacing.l)
    }

    private var continueTitle: String {
        switch model.step {
        case .welcome: "Get Started"
        case .screenRecording: permissions.screenRecordingGranted ? "Continue" : "Later"
        case .accessibility: permissions.accessibilityGranted ? "Continue" : "Skip"
        default: "Continue"
        }
    }

    private var cardBackground: some View {
        RoundedRectangle(cornerRadius: Tokens.Radius.settingsCard, style: .continuous)
            .fill(Color.dsSettingsCard)
            .overlay {
                RoundedRectangle(cornerRadius: Tokens.Radius.settingsCard, style: .continuous)
                    .strokeBorder(Color(nsColor: Tokens.Palette.settingsCardBorder), lineWidth: Tokens.Stroke.hairline)
            }
    }
}

// MARK: - Pieces

/// Symbol badge, title, message, then the step's controls.
private struct StepLayout<Content: View>: View {
    let symbol: String
    let title: String
    let message: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Spacing.l) {
            HStack(spacing: Tokens.Spacing.m) {
                Image(systemName: symbol)
                    .font(.system(size: Tokens.Onboarding.badgeSymbol, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: Tokens.Onboarding.badge, height: Tokens.Onboarding.badge)
                    .background(
                        RoundedRectangle(cornerRadius: Tokens.Radius.settingsIconBadge, style: .continuous)
                            .fill(Color.accentColor.gradient)
                    )
                Text(title).font(Tokens.Typography.settingsTitle)
            }
            Text(message)
                .font(Tokens.Typography.rowLabel)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            content
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct PermissionCard: View {
    let title: String
    let detail: String
    let granted: Bool
    let required: Bool
    let grant: () -> Void
    let openSettings: () -> Void

    var body: some View {
        HStack(spacing: Tokens.Spacing.m) {
            Image(systemName: granted ? "checkmark.circle.fill" : (required ? "xmark.circle.fill" : "circle.dashed"))
                .font(.system(size: Tokens.Onboarding.statusSymbol))
                .foregroundStyle(granted ? Color.green : (required ? Color.red : Color.secondary))
                .contentTransition(.symbolEffect(.replace))
            VStack(alignment: .leading, spacing: Tokens.Spacing.settingsRowTextGap) {
                Text(title).font(Tokens.Typography.rowLabel.weight(.semibold))
                Text(detail)
                    .font(Tokens.Typography.rowDescription)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if !granted {
                Button("Open Settings", action: openSettings)
                    .buttonStyle(PillButtonStyle(style: .neutral))
                Button("Grant Access", action: grant)
                    .buttonStyle(PillButtonStyle(style: .primary))
            }
        }
        .padding(.vertical, Tokens.Spacing.settingsRowV)
        .padding(.horizontal, Tokens.Spacing.settingsRowH)
        .background(
            RoundedRectangle(cornerRadius: Tokens.Radius.settingsCard, style: .continuous)
                .fill(Color.dsSettingsCard)
                .overlay {
                    RoundedRectangle(cornerRadius: Tokens.Radius.settingsCard, style: .continuous)
                        .strokeBorder(Color(nsColor: Tokens.Palette.settingsCardBorder), lineWidth: Tokens.Stroke.hairline)
                }
        )
        .animation(DSAnimation.hoverControls, value: granted)
    }
}

/// One recording permission: what it is for, its current status and a
/// System Settings button. Never requests access.
private struct RecordingPermissionRow: View {
    enum Status: Equatable {
        case granted, denied, notAsked

        init(_ authorization: MediaAuthorization) {
            switch authorization {
            case .authorized: self = .granted
            case .denied, .restricted: self = .denied
            case .notDetermined: self = .notAsked
            }
        }

        init(_ status: InputMonitoringPermission.Status) {
            switch status {
            case .granted: self = .granted
            case .denied: self = .denied
            case .notDetermined: self = .notAsked
            }
        }

        var label: String {
            switch self {
            case .granted: "Allowed"
            case .denied: "Off"
            case .notAsked: "Asked on first use"
            }
        }

        var color: Color {
            switch self {
            case .granted: .green
            case .denied: .orange
            case .notAsked: .secondary
            }
        }
    }

    let symbol: String
    let title: String
    let detail: String
    let status: Status
    let openSettings: () -> Void

    var body: some View {
        HStack(spacing: Tokens.Spacing.m) {
            Image(systemName: symbol)
                .font(.system(size: Tokens.Onboarding.statusSymbol - 4))
                .foregroundStyle(.secondary)
                .frame(width: Tokens.Onboarding.statusSymbol)
            VStack(alignment: .leading, spacing: Tokens.Spacing.settingsRowTextGap) {
                Text(title).font(Tokens.Typography.rowLabel.weight(.semibold))
                Text(detail)
                    .font(Tokens.Typography.rowDescription)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text(status.label)
                .font(Tokens.Typography.rowDescription.weight(.semibold))
                .foregroundStyle(status.color)
            Button("Open Settings", action: openSettings)
                .buttonStyle(PillButtonStyle(style: .neutral))
        }
        .padding(.vertical, Tokens.Onboarding.shortcutRowV)
        .padding(.horizontal, Tokens.Spacing.settingsRowH)
        .accessibilityElement(children: .combine)
    }
}

private struct SystemShortcutRow: View {
    let shortcut: SystemScreenshotShortcut

    var body: some View {
        HStack(spacing: Tokens.Spacing.m) {
            Text(shortcut.combo.modifierSymbols + keyLabel)
                .font(Tokens.Typography.rowLabel.monospacedDigit().weight(.medium))
                .frame(width: Tokens.Onboarding.comboColumn, alignment: .leading)
            Text(shortcut.title)
                .font(Tokens.Typography.rowLabel)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer()
            Text(shortcut.isEnabled ? "On" : "Off")
                .font(Tokens.Typography.rowDescription.weight(.semibold))
                .foregroundStyle(shortcut.isEnabled ? Color.orange : Color.green)
        }
        .padding(.vertical, Tokens.Onboarding.shortcutRowV)
        .padding(.horizontal, Tokens.Spacing.settingsRowH)
    }

    /// Digit keys only (the five defaults are 3/4/5); others show their key code.
    private var keyLabel: String {
        switch shortcut.combo.keyCode {
        case kVK_ANSI_3: "3"
        case kVK_ANSI_4: "4"
        case kVK_ANSI_5: "5"
        default: "#\(shortcut.combo.keyCode)"
        }
    }
}

private struct Note: View {
    let text: String

    var body: some View {
        Text(text)
            .font(Tokens.Typography.rowDescription)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

private struct StepDots: View {
    let current: OnboardingStep

    var body: some View {
        HStack(spacing: Tokens.Spacing.s) {
            ForEach(OnboardingStep.allCases) { step in
                Circle()
                    .fill(step == current ? Color.accentColor : Color.secondary.opacity(0.3))
                    .frame(width: Tokens.Onboarding.dot, height: Tokens.Onboarding.dot)
            }
        }
        .accessibilityElement()
        .accessibilityLabel("Step \(current.rawValue + 1) of \(OnboardingStep.allCases.count)")
    }
}

extension Notification.Name {
    /// Posted by Settings › About to show the onboarding window again.
    static let showOnboarding = Notification.Name("com.hakanyucel.HakoShot.showOnboarding")
}
