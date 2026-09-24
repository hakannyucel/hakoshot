import AppKit
import SwiftUI

/// The Background sidebar (report §9.3), left of the canvas scroll view: a
/// hosting view sized by its SwiftUI content (0 pt wide while the panel is
/// hidden). `EditorWindowController.buildViews` pins the scroll view's leading
/// edge to its trailing edge.
enum BackgroundPanelHost {
    static func makeView(model: EditorViewModel) -> NSView {
        let host = FirstMouseHostingView(rootView: BackgroundPanelContainer(model: model))
        host.identifier = NSUserInterfaceItemIdentifier("HakoBackgroundPanel")
        host.sizingOptions = [.intrinsicContentSize]
        host.setContentHuggingPriority(.required, for: .horizontal)
        host.setContentCompressionResistancePriority(.required, for: .horizontal)
        return host
    }
}

/// Shows the panel only while `showsBackgroundPanel` is on.
private struct BackgroundPanelContainer: View {
    let model: EditorViewModel

    var body: some View {
        if model.showsBackgroundPanel {
            BackgroundPanelView(model: model)
                .frame(width: EditorMetrics.backgroundPanelWidth)
                .frame(maxHeight: .infinity)
        } else {
            Color.clear.frame(width: 0)
        }
    }
}
