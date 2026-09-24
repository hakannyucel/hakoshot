import AppKit
import QuartzCore
import SwiftUI

/// Named motion curves built from `Tokens.Duration`. All values are suggestions
/// (report: durations could not be measured from stills).
///
/// SwiftUI: `withAnimation(DSAnimation.hoverControls) { … }`.
/// AppKit: `DSAnimation.run(.overlayFadeIn) { ctx in window.animator().alphaValue = 1 }`.
enum DSAnimation {
    static var popoverIn: Animation { .easeOut(duration: Tokens.Duration.popoverIn) }
    static var overlayFadeIn: Animation { .easeOut(duration: Tokens.Duration.overlayFadeIn) }
    static var quickAccessSlideIn: Animation {
        .spring(duration: Tokens.Duration.quickAccessSlideIn, bounce: 1 - Tokens.Duration.quickAccessSpringDamping)
    }
    static var hoverControls: Animation { .easeInOut(duration: Tokens.Duration.hoverControlsFade) }
    static var toastIn: Animation { .easeOut(duration: Tokens.Duration.toastIn) }
    static var toastOut: Animation { .easeIn(duration: Tokens.Duration.toastOut) }

    /// True when the user asked macOS to reduce motion; callers should fade instead of slide.
    static var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    /// Returns `animation`, or a short cross-fade when Reduce Motion is on.
    static func respectingReduceMotion(_ animation: Animation) -> Animation {
        reduceMotion ? .easeInOut(duration: Tokens.Duration.hoverControlsFade) : animation
    }

    // MARK: AppKit / Core Animation

    enum Curve {
        case popoverIn, overlayFadeIn, quickAccessSlideIn, hoverControls, toastIn, toastOut

        var duration: TimeInterval {
            switch self {
            case .popoverIn: Tokens.Duration.popoverIn
            case .overlayFadeIn: Tokens.Duration.overlayFadeIn
            case .quickAccessSlideIn: Tokens.Duration.quickAccessSlideIn
            case .hoverControls: Tokens.Duration.hoverControlsFade
            case .toastIn: Tokens.Duration.toastIn
            case .toastOut: Tokens.Duration.toastOut
            }
        }

        var timingFunction: CAMediaTimingFunction {
            switch self {
            case .popoverIn, .overlayFadeIn, .toastIn: CAMediaTimingFunction(name: .easeOut)
            case .toastOut: CAMediaTimingFunction(name: .easeIn)
            case .hoverControls: CAMediaTimingFunction(name: .easeInEaseOut)
            // Approximation of a 0.8-damped spring for NSAnimationContext.
            case .quickAccessSlideIn: CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.25, 1.0)
            }
        }
    }

    /// Extra wait before the fallback completion fires (see `run`).
    static let completionGrace: TimeInterval = 0.3

    /// Runs an `NSAnimationContext` group with the token duration/curve.
    ///
    /// `completion` runs exactly once: when the group finishes, or at the
    /// latest `duration + completionGrace` later. With the displays asleep
    /// AppKit may never finish window animations, which used to leave a
    /// closed (invisible) panel on screen; callers order windows out here.
    static func run(
        _ curve: Curve,
        changes: @escaping (NSAnimationContext) -> Void,
        completion: (@MainActor () -> Void)? = nil
    ) {
        let duration = reduceMotion ? min(curve.duration, Tokens.Duration.hoverControlsFade) : curve.duration
        let once = completion.map(OnceAction.init)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = duration
            context.timingFunction = curve.timingFunction
            context.allowsImplicitAnimation = true
            changes(context)
        } completionHandler: {
            MainActor.assumeIsolated { once?.run() }
        }
        if let once {
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(duration + completionGrace))
                once.run()
            }
        }
    }

    /// A closure that runs at most once.
    private final class OnceAction {
        private var action: (@MainActor () -> Void)?
        init(_ action: @escaping @MainActor () -> Void) { self.action = action }
        func run() {
            let action = self.action
            self.action = nil
            action?()
        }
    }
}

// MARK: - Copy flash

/// Quick Access "Copy" feedback: the card briefly darkens, then returns (report §7).
/// Toggle `trigger` (any Equatable change) to fire it.
struct CopyFlashModifier<Trigger: Equatable>: ViewModifier {
    let trigger: Trigger
    var cornerRadius: CGFloat = Tokens.Radius.quickAccessCard
    @State private var flashing = false

    func body(content: Content) -> some View {
        content.overlay {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(Color.black.opacity(flashing ? 0.55 : 0))
                .allowsHitTesting(false)
        }
        .onChange(of: trigger) {
            let half = Tokens.Duration.copyFlash / 2
            withAnimation(.easeOut(duration: half)) { flashing = true }
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(half))
                withAnimation(.easeIn(duration: half)) { flashing = false }
            }
        }
    }
}

extension View {
    func copyFlash<T: Equatable>(trigger: T, cornerRadius: CGFloat = Tokens.Radius.quickAccessCard) -> some View {
        modifier(CopyFlashModifier(trigger: trigger, cornerRadius: cornerRadius))
    }
}
