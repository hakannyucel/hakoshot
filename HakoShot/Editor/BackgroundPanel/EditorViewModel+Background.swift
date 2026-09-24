import AppKit
import CoreGraphics
import HakoKit
import ImageIO
import UniformTypeIdentifiers
import os

extension SettingsKey where Value == String {
    /// Saved Background presets, JSON `[BackgroundPreset]`.
    static var editorBackgroundPresets: SettingsKey<String> { SettingsKey("editorBackgroundPresets", default: "") }
    /// Last background style used (JSON `BackgroundStyle`); the next "on" starts from it.
    static var editorBackgroundLastStyle: SettingsKey<String> { SettingsKey("editorBackgroundLastStyle", default: "") }
}

/// A named Background style (panel "Presets…" menu).
nonisolated struct BackgroundPreset: Codable, Hashable, Sendable, Identifiable {
    var id = UUID()
    var name: String
    var style: BackgroundStyle
}

/// Presets / last style persistence (pure JSON helpers, tested).
nonisolated enum BackgroundPresetStore {
    static func decode(_ json: String) -> [BackgroundPreset] {
        guard let data = json.data(using: .utf8), !data.isEmpty,
              let presets = try? JSONDecoder().decode([BackgroundPreset].self, from: data) else { return [] }
        return presets
    }

    static func encode(_ presets: [BackgroundPreset]) -> String {
        guard let data = try? JSONEncoder().encode(presets) else { return "" }
        return String(decoding: data, as: UTF8.self)
    }

    /// A style that can travel to other documents: image assets belong to one
    /// document, so an image fill falls back to the default gradient.
    static func portable(_ style: BackgroundStyle) -> BackgroundStyle {
        var copy = style
        if case .image = copy.fill { copy.fill = BackgroundStyle.standard.fill }
        return copy
    }

    /// "Preset 3" — the first unused number.
    static func nextName(after presets: [BackgroundPreset]) -> String {
        let names = Set(presets.map(\.name))
        var n = presets.count + 1
        while names.contains("Preset \(n)") { n += 1 }
        return "Preset \(n)"
    }
}

/// Background tool (WP5.2, report §9.3). Every change is `setBackground`;
/// slider drags are wrapped in `beginBackgroundEdit` / `endBackgroundEdit` so
/// a drag is one undo step.
extension EditorViewModel {
    var background: BackgroundStyle? { store.document.background }

    /// B / capsule button.
    func toggleBackgroundPanel() {
        if isCropping { cancelCrop() }
        showsBackgroundPanel.toggle()
    }

    /// Style used when switching the background on.
    var defaultBackgroundStyle: BackgroundStyle {
        if let lastBackgroundStyle { return lastBackgroundStyle }
        let json = settings.value(for: .editorBackgroundLastStyle)
        if let data = json.data(using: .utf8), let style = try? JSONDecoder().decode(BackgroundStyle.self, from: data) {
            return style
        }
        return .standard
    }

    func setBackgroundEnabled(_ on: Bool) {
        if on {
            guard background == nil else { return }
            perform(.setBackground(defaultBackgroundStyle))
        } else {
            guard let current = background else { return }
            lastBackgroundStyle = current
            perform(.setBackground(nil))
        }
    }

    /// Changes the style (switching the background on if needed).
    func updateBackground(_ body: (inout BackgroundStyle) -> Void) {
        var style = background ?? defaultBackgroundStyle
        body(&style)
        guard style != background else { return }
        perform(.setBackground(style))
        rememberBackground(style)
    }

    func setBackgroundFill(_ fill: BackgroundFill) {
        updateBackground { $0.fill = fill }
    }

    /// Slider drag start / end (one undo step per drag).
    func beginBackgroundEdit() {
        if !store.isInteracting { beginInteraction("Background") }
    }

    func endBackgroundEdit() {
        if store.isInteracting { endInteraction() }
    }

    /// Color panel streams: one undo step after a pause.
    func setBackgroundFillCoalesced(_ fill: BackgroundFill) {
        beginBackgroundEdit()
        setBackgroundFill(fill)
        backgroundCoalesceTask?.cancel()
        backgroundCoalesceTask = Task { [weak self] in
            try? await Task.sleep(for: EditorMetrics.colorPanelCoalesce)
            guard !Task.isCancelled else { return }
            self?.endBackgroundEdit()
        }
    }

    private func rememberBackground(_ style: BackgroundStyle) {
        lastBackgroundStyle = style
        guard let data = try? JSONEncoder().encode(BackgroundPresetStore.portable(style)) else { return }
        settings.set(String(decoding: data, as: UTF8.self), for: .editorBackgroundLastStyle)
    }

    // MARK: Presets

    var backgroundPresets: [BackgroundPreset] {
        _ = backgroundPresetsRevision
        return BackgroundPresetStore.decode(settings.value(for: .editorBackgroundPresets))
    }

    /// "+" next to Presets: saves the current style.
    func saveBackgroundPreset() {
        guard let style = background else { return }
        var presets = backgroundPresets
        presets.append(BackgroundPreset(name: BackgroundPresetStore.nextName(after: presets), style: BackgroundPresetStore.portable(style)))
        settings.set(BackgroundPresetStore.encode(presets), for: .editorBackgroundPresets)
        backgroundPresetsRevision += 1
        showStatus("Saved background preset")
    }

    func applyBackgroundPreset(_ preset: BackgroundPreset) {
        perform(.setBackground(preset.style))
        rememberBackground(preset.style)
    }

    func deleteBackgroundPreset(_ preset: BackgroundPreset) {
        let presets = backgroundPresets.filter { $0.id != preset.id }
        settings.set(BackgroundPresetStore.encode(presets), for: .editorBackgroundPresets)
        backgroundPresetsRevision += 1
    }

    // MARK: Images

    /// Adds an image to the document's assets (not undoable itself; the fill change is).
    func addAsset(_ image: CGImage) -> AssetID {
        let id = AssetID()
        assetBox.insert(image, for: id)
        return id
    }

    /// Wallpaper "+": pick an image file.
    func chooseBackgroundImage(from window: NSWindow?) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        let handle: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            self?.useBackgroundImage(at: url)
        }
        if let window { panel.beginSheetModal(for: window, completionHandler: handle) } else { handle(panel.runModal()) }
    }

    /// The desktop picture of the screen the editor is on.
    func useDesktopWallpaper(screen: NSScreen?) {
        guard let screen = screen ?? NSScreen.main, let url = NSWorkspace.shared.desktopImageURL(for: screen) else {
            showStatus("No desktop picture found")
            return
        }
        useBackgroundImage(at: url)
    }

    func useBackgroundImage(at url: URL) {
        guard let image = Self.loadImage(at: url, maxPixelSize: 4096) else {
            showStatus("Could not open \(url.lastPathComponent)")
            Self.log.error("background image load failed: \(url.path, privacy: .public)")
            return
        }
        setBackgroundFill(.image(addAsset(image)))
    }

    /// Image file, downscaled so its longer side is at most `maxPixelSize`.
    nonisolated static func loadImage(at url: URL, maxPixelSize: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    /// The image of the current `.image` fill (panel swatch).
    var backgroundImageAsset: (AssetID, CGImage)? {
        guard case .image(let id)? = background?.fill, let image = assetBox.image(for: id) else { return nil }
        return (id, image)
    }
}

/// HakoKit's `BackgroundStyle`, for SwiftUI files (where the name clashes
/// with SwiftUI's `BackgroundStyle`).
typealias DocumentBackgroundStyle = BackgroundStyle
