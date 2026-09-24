import AppKit
import SwiftUI

/// Dark, rounded vibrancy panel used by every "floating over the desktop" surface
/// (All-In-One bar, History overlay, toasts, Pin hover bar). Always dark: the HUD
/// language is theme-independent (report §3, §13).
///
/// Rounded corners use `maskImage` (the supported way to round an
/// `NSVisualEffectView`; layer `cornerRadius` does not clip the blur).
final class HUDMaterialView: NSVisualEffectView {

    var cornerRadius: CGFloat {
        didSet { if cornerRadius != oldValue { updateMask() } }
    }

    init(
        cornerRadius: CGFloat = Tokens.Radius.hudBar,
        blendingMode: NSVisualEffectView.BlendingMode = .behindWindow
    ) {
        self.cornerRadius = cornerRadius
        super.init(frame: .zero)
        material = .hudWindow
        self.blendingMode = blendingMode
        state = .active
        appearance = NSAppearance(named: .darkAqua)
        wantsLayer = true
        updateMask()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    private func updateMask() {
        maskImage = cornerRadius > 0 ? Self.roundedMask(radius: cornerRadius) : nil
    }

    /// Stretchable rounded-rect mask; cap insets keep the corners fixed at any size.
    static func roundedMask(radius: CGFloat) -> NSImage {
        let edge = radius * 2 + 1
        let image = NSImage(size: NSSize(width: edge, height: edge), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        image.resizingMode = .stretch
        return image
    }
}

// MARK: - SwiftUI

/// SwiftUI wrapper of `HUDMaterialView`.
struct HUDMaterial: NSViewRepresentable {
    var cornerRadius: CGFloat = Tokens.Radius.hudBar
    /// `.withinWindow` when the panel sits over other content of the same window
    /// (e.g. previews); `.behindWindow` for transparent floating panels.
    var blendingMode: NSVisualEffectView.BlendingMode = .behindWindow

    func makeNSView(context: Context) -> HUDMaterialView {
        HUDMaterialView(cornerRadius: cornerRadius, blendingMode: blendingMode)
    }

    func updateNSView(_ view: HUDMaterialView, context: Context) {
        view.cornerRadius = cornerRadius
        view.blendingMode = blendingMode
    }
}

extension View {
    /// Places the content on a dark HUD panel: blur material, hairline border, HUD shadow,
    /// dark color scheme for the content.
    func hudPanel(
        cornerRadius: CGFloat = Tokens.Radius.hudBar,
        blendingMode: NSVisualEffectView.BlendingMode = .behindWindow,
        shadow: Tokens.Shadow? = .hudBar
    ) -> some View {
        // Circular corners, like the blur mask (`roundedMask`): a continuous
        // border poked out past the mask (square-ish hairline around the
        // self-timer circle, flat ends on the All-In-One bar).
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .circular)
        return self
            .environment(\.colorScheme, .dark)
            .background {
                ZStack {
                    // Platform views don't cast SwiftUI shadows; a faint shape underneath does.
                    if let shadow {
                        shape.fill(Color.black.opacity(0.2)).dsShadow(shadow)
                    }
                    HUDMaterial(cornerRadius: cornerRadius, blendingMode: blendingMode)
                    shape.strokeBorder(Color(nsColor: Tokens.Palette.hudBorder), lineWidth: Tokens.Stroke.hairline)
                }
            }
    }
}
