#if DEBUG
import AppKit
import SwiftUI

/// DEBUG-only catalog window: every design-system component side by side in
/// light (left) and dark (right). Each half is its own `NSHostingView` with a
/// forced `NSAppearance`, so dynamic `NSColor` tokens resolve correctly.
///
/// Open with `DesignSystemPreviewWindow.show()` (e.g. from a debug menu item).
enum DesignSystemPreviewWindow {
    private static var window: NSWindow?

    static func show() {
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate()
            return
        }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1120, height: 820),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "HakoShot Design System (DEBUG)"
        window.isReleasedWhenClosed = false
        window.contentView = makeContentView()
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
        self.window = window
    }

    /// Side-by-side light/dark content (also used by the render sanity check).
    static func makeContentView() -> NSView {
        let stack = NSStackView(views: [
            makeHalf(appearance: .aqua, title: "Light"),
            makeHalf(appearance: .darkAqua, title: "Dark"),
        ])
        stack.orientation = .horizontal
        stack.distribution = .fillEqually
        stack.spacing = 0
        return stack
    }

    static func makeHalf(appearance: NSAppearance.Name, title: String) -> NSView {
        let host = NSHostingView(rootView:
            ScrollView {
                DesignSystemCatalog(title: title)
                    .padding(Tokens.Spacing.xl)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(Color(nsColor: .windowBackgroundColor))
            .environment(\.colorScheme, appearance == .darkAqua ? .dark : .light)
        )
        host.appearance = NSAppearance(named: appearance)
        return host
    }
}

// MARK: - Catalog

private struct DesignSystemCatalog: View {
    let title: String
    @State private var toggleOn = true
    @State private var picker = "PNG"
    @State private var slider = 0.6
    @State private var forceHover = true
    @State private var flashCount = 0

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Spacing.xl) {
            Text(title).font(Tokens.Typography.settingsTitle)

            section("Colors") { colors }
            section("Radii") { radii }
            section("Strokes") { strokes }
            section("Typography") { typography }
            section("Shadows") { shadows }
            section("Pill buttons") { pills }
            section("Circle icon buttons") { circles }
            section("HUD material") { hud }
            section("Hover controls (Quick Access)") { hover }
            section("Settings card + rows") { settings }
            section("Motion") { motion }
        }
    }

    private func section<C: View>(_ name: String, @ViewBuilder content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: Tokens.Spacing.s) {
            Text(name)
                .font(Tokens.Typography.sectionHeader)
                .foregroundStyle(Color(nsColor: Tokens.Palette.textSecondary))
            content()
        }
    }

    // MARK: Sections

    private var colors: some View {
        let items: [(String, NSColor)] = [
            ("accent", Tokens.Palette.accent),
            ("stroke", Tokens.Palette.annotationStroke),
            ("counter", Tokens.Palette.annotationCounterFill),
            ("highlight", Tokens.Palette.annotationHighlighter),
            ("card", Tokens.Palette.settingsCard),
            ("divider", Tokens.Palette.divider),
            ("selection", Tokens.Palette.selectionFill),
            ("hudScrim", Tokens.Palette.hudScrim),
            ("hudCtrl", Tokens.Palette.hudControlFill),
            ("hudLight", Tokens.Palette.hudLightFill),
        ]
        return LazyVGrid(columns: Array(repeating: GridItem(.fixed(Tokens.Size.swatch), spacing: Tokens.Spacing.swatchGap), count: 5),
                         alignment: .leading, spacing: Tokens.Spacing.swatchGap) {
            ForEach(items, id: \.0) { name, color in
                VStack(spacing: Tokens.Spacing.xs) {
                    RoundedRectangle(cornerRadius: Tokens.Radius.swatchSmall, style: .continuous)
                        .fill(Color(nsColor: color))
                        .overlay(RoundedRectangle(cornerRadius: Tokens.Radius.swatchSmall, style: .continuous)
                            .strokeBorder(Color.dsDivider, lineWidth: Tokens.Stroke.hairline))
                        .frame(width: Tokens.Size.swatch, height: Tokens.Size.swatch * 0.6)
                    Text(name).font(Tokens.Typography.hudLabel).foregroundStyle(.secondary)
                }
            }
        }
    }

    private var radii: some View {
        let items: [(String, CGFloat)] = [
            ("swatch", Tokens.Radius.swatchSmall), ("card", Tokens.Radius.settingsCard),
            ("QA card", Tokens.Radius.quickAccessCard), ("window", Tokens.Radius.windowOuter),
            ("hudBar", Tokens.Radius.hudBar),
        ]
        return HStack(spacing: Tokens.Spacing.m) {
            ForEach(items, id: \.0) { name, radius in
                VStack(spacing: Tokens.Spacing.xs) {
                    RoundedRectangle(cornerRadius: radius, style: .continuous)
                        .strokeBorder(Color.accentColor, lineWidth: Tokens.Stroke.thin)
                        .frame(width: 64, height: 64)
                    Text("\(name) \(Int(radius))").font(Tokens.Typography.hudLabel).foregroundStyle(.secondary)
                }
            }
        }
    }

    private var strokes: some View {
        HStack(alignment: .center, spacing: Tokens.Spacing.l) {
            ForEach(Tokens.Stroke.annotationPresets, id: \.self) { width in
                VStack(spacing: Tokens.Spacing.xs) {
                    Capsule()
                        .fill(Color(nsColor: Tokens.Palette.annotationStroke))
                        .frame(width: 56, height: width)
                        .frame(height: Tokens.Stroke.extraThick)
                    Text("\(Int(width)) pt").font(Tokens.Typography.hudLabel).foregroundStyle(.secondary)
                }
            }
        }
    }

    private var typography: some View {
        VStack(alignment: .leading, spacing: Tokens.Spacing.xs) {
            Text("Settings title").font(Tokens.Typography.settingsTitle)
            Text("Section header").font(Tokens.Typography.sectionHeader)
            Text("Row label").font(Tokens.Typography.rowLabel)
            Text("Row description, secondary").font(Tokens.Typography.rowDescription).foregroundStyle(.secondary)
            Text("1 044 × 320").font(Tokens.Typography.dimensionLabel)
            Text("Pill label").font(Tokens.Typography.pillLabel)
        }
    }

    private var shadows: some View {
        let items: [(String, Tokens.Shadow)] = [
            ("floatingCard", .floatingCard), ("hudBar", .hudBar), ("toast", .toast), ("settingsCard", .settingsCard),
        ]
        return HStack(spacing: Tokens.Spacing.xl) {
            ForEach(items, id: \.0) { name, token in
                VStack(spacing: Tokens.Spacing.s) {
                    RoundedRectangle(cornerRadius: Tokens.Radius.quickAccessCard, style: .continuous)
                        .fill(Color(nsColor: .controlBackgroundColor))
                        .frame(width: 72, height: 52)
                        .dsShadow(token)
                    Text(name).font(Tokens.Typography.hudLabel).foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, Tokens.Spacing.s)
    }

    private var pills: some View {
        VStack(alignment: .leading, spacing: Tokens.Spacing.m) {
            HStack(spacing: Tokens.Spacing.s) {
                PillButton("Done", systemImage: "checkmark", style: .primary) {}
                PillButton("Save as…", style: .neutral) {}
                PillButton("Disabled", style: .neutral) {}.disabled(true)
            }
            HStack(spacing: Tokens.Spacing.s) {
                PillButton("Cancel", systemImage: "xmark", style: .hudDark) {}
                PillButton("Done", systemImage: "checkmark", style: .hudLight) {}
                PillButton("100%", style: .hudDark) {}
            }
            .padding(Tokens.Spacing.m)
            .background(checkerboardBackdrop)
        }
    }

    private var circles: some View {
        HStack(spacing: Tokens.Spacing.m) {
            CircleIconButton(systemImage: "xmark", accessibilityLabel: "Close") {}
            CircleIconButton(systemImage: "pin.fill", accessibilityLabel: "Pin") {}
            CircleIconButton(systemImage: "pencil", accessibilityLabel: "Edit") {}
            CircleIconButton(systemImage: "folder", accessibilityLabel: "Show in Finder") {}
            Divider().frame(height: Tokens.Size.circleButton)
            CircleIconButton(systemImage: "square.and.arrow.up", accessibilityLabel: "Share", style: .light) {}
            CircleIconButton(systemImage: "doc.on.doc", accessibilityLabel: "Copy", style: .light) {}
        }
        .padding(Tokens.Spacing.m)
        .background(checkerboardBackdrop)
    }

    private var hud: some View {
        let modes: [(String, String)] = [
            ("viewfinder", "Area"), ("display", "Fullscreen"), ("macwindow", "Window"),
            ("arrow.down.to.line", "Scrolling"), ("timer", "Timer"), ("textformat", "OCR"),
        ]
        return HStack(spacing: Tokens.Spacing.hudItemGap) {
            ForEach(Array(modes.enumerated()), id: \.offset) { index, mode in
                VStack(spacing: Tokens.Spacing.xs) {
                    Image(systemName: mode.0).font(.system(size: Tokens.Size.hudIcon, weight: .regular))
                    Text(mode.1).font(Tokens.Typography.hudLabel)
                        .foregroundStyle(Color(nsColor: Tokens.Palette.hudTextSecondary))
                }
                .foregroundStyle(Color(nsColor: Tokens.Palette.hudTextPrimary))
                .padding(.horizontal, Tokens.Spacing.s)
                .padding(.vertical, Tokens.Spacing.s)
                .background {
                    if index == 2 {
                        RoundedRectangle(cornerRadius: Tokens.Radius.hudItemHighlight, style: .continuous)
                            .fill(Color(nsColor: Tokens.Palette.hudItemHighlight))
                    }
                }
            }
        }
        .padding(.horizontal, Tokens.Spacing.hudBarPaddingH)
        .padding(.vertical, Tokens.Spacing.s)
        .hudPanel(blendingMode: .withinWindow)
        .padding(Tokens.Spacing.l)
        .background(checkerboardBackdrop)
    }

    private var hover: some View {
        VStack(alignment: .leading, spacing: Tokens.Spacing.s) {
            Toggle("Force visible (otherwise hover)", isOn: $forceHover)
            HStack(spacing: Tokens.Spacing.l) {
                fakeCapture
                    .hoverControls(
                        topLeading: HoverCornerControl(systemImage: "xmark", label: "Close") {},
                        topTrailing: HoverCornerControl(systemImage: "pin.fill", label: "Pin") {},
                        bottomLeading: HoverCornerControl(systemImage: "pencil", label: "Edit") {},
                        bottomTrailing: HoverCornerControl(systemImage: "folder", label: "Show in Finder") {},
                        centerPills: [
                            HoverPillControl(title: "Copy") { flashCount += 1 },
                            HoverPillControl(title: "Save") {},
                        ],
                        forceVisible: forceHover
                    )
                    .copyFlash(trigger: flashCount)
                    .dsShadow(.floatingCard)
                fakeCapture.dsShadow(.floatingCard)
            }
            .padding(Tokens.Spacing.s)
        }
    }

    private var settings: some View {
        VStack(alignment: .leading, spacing: Tokens.Spacing.cardGap) {
            SettingsCard("After capture") {
                SettingsRow("Play sound") { Toggle("Play sound", isOn: $toggleOn).toggleStyle(.switch) }
                SettingsRow("File format", description: "Used for Save and drag & drop.") {
                    Picker("File format", selection: $picker) {
                        Text("PNG").tag("PNG"); Text("JPEG").tag("JPEG"); Text("HEIC").tag("HEIC")
                    }
                    .fixedSize()
                }
                SettingsRow("Overlay size") { Slider(value: $slider).frame(width: 140) }
                SettingsRow("Export location", description: "~/Desktop") {
                    PillButton("Choose…", style: .neutral) {}
                }
            }
            SettingsCard {
                SettingsRow("Text-only row", description: "No trailing control.")
            }
        }
        .frame(maxWidth: 480)
    }

    private var motion: some View {
        VStack(alignment: .leading, spacing: Tokens.Spacing.xs) {
            Text(String(format: "popoverIn %.0f ms · overlayFadeIn %.0f ms · quickAccessSlideIn %.0f ms (spring %.1f)",
                        Tokens.Duration.popoverIn * 1000, Tokens.Duration.overlayFadeIn * 1000,
                        Tokens.Duration.quickAccessSlideIn * 1000, Tokens.Duration.quickAccessSpringDamping))
            Text(String(format: "hoverControls %.0f ms · copyFlash %.0f ms · toast %.0f / %.0f / %.0f ms",
                        Tokens.Duration.hoverControlsFade * 1000, Tokens.Duration.copyFlash * 1000,
                        Tokens.Duration.toastIn * 1000, Tokens.Duration.toastHold * 1000, Tokens.Duration.toastOut * 1000))
            PillButton("Fire copy flash", systemImage: "bolt.fill", style: .primary) { flashCount += 1 }
        }
        .font(Tokens.Typography.rowDescription)
        .foregroundStyle(.secondary)
    }

    // MARK: Helpers

    /// Stand-in screenshot for the Quick Access card.
    private var fakeCapture: some View {
        RoundedRectangle(cornerRadius: Tokens.Radius.quickAccessCard, style: .continuous)
            .fill(LinearGradient(colors: [.orange, .pink, .purple], startPoint: .topLeading, endPoint: .bottomTrailing))
            .overlay(alignment: .topLeading) {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(0..<5, id: \.self) { row in
                        Capsule().fill(.white.opacity(0.5)).frame(width: CGFloat(60 + row * 18), height: 6)
                    }
                }
                .padding(Tokens.Spacing.l)
            }
            .frame(width: Tokens.Size.quickAccessCardWidth, height: Tokens.Size.quickAccessCardWidth * 0.66)
    }

    /// Busy backdrop so translucent HUD fills are judged against something wallpaper-like.
    private var checkerboardBackdrop: some View {
        LinearGradient(colors: [Color(red: 0.25, green: 0.45, blue: 0.75), Color(red: 0.85, green: 0.55, blue: 0.4)],
                       startPoint: .leading, endPoint: .trailing)
            .clipShape(RoundedRectangle(cornerRadius: Tokens.Radius.settingsCard, style: .continuous))
    }
}
#endif
