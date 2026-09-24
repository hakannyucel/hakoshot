import AppKit
import SwiftUI

/// Progress sheet shown while a Save / Save As / Copy renders, with Cancel
/// (cancelling leaves no file: `RenderPipeline` deletes its partial file).
struct VideoExportSheet: View {
    let model: VideoEditorViewModel

    var body: some View {
        let state = model.exportState ?? VideoExportState(title: "Preparing…", progress: 0)
        VStack(alignment: .leading, spacing: Tokens.Spacing.m) {
            Text(state.title)
                .font(.system(size: 13, weight: .semibold))
            ProgressView(value: min(max(state.progress, 0), 1))
                .progressViewStyle(.linear)
            HStack {
                Text(verbatim: "\(Int((state.progress * 100).rounded(.down))) %")
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(Color(nsColor: Tokens.Palette.textSecondary))
                Spacer()
                Button("Cancel") { model.cancelExport() }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(Tokens.Spacing.xl)
        .frame(width: VideoEditorMetrics.exportSheetWidth)
    }
}

/// Presents `VideoExportSheet` as a window sheet for the lifetime of one
/// export task.
final class VideoExportSheetPresenter {
    private var sheet: NSWindow?

    func present(on window: NSWindow, model: VideoEditorViewModel) {
        guard sheet == nil else { return }
        let hosting = NSHostingController(rootView: VideoExportSheet(model: model))
        let sheet = NSWindow(contentViewController: hosting)
        sheet.styleMask = [.titled]
        self.sheet = sheet
        window.beginSheet(sheet)
    }

    func dismiss() {
        guard let sheet else { return }
        sheet.sheetParent?.endSheet(sheet)
        sheet.orderOut(nil)
        self.sheet = nil
    }
}
