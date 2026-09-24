import AppKit
import HakoKit
import SwiftUI

struct AdvancedSettingsPage: View {
    @AppStorage(.historyEnabled) private var historyEnabled: Bool
    @AppStorage(.historyRetention) private var historyRetention: HistoryRetention
    @AppStorage(.pinRoundedCorners) private var pinRoundedCorners: Bool
    @AppStorage(.pinShowShadow) private var pinShowShadow: Bool
    @AppStorage(.pinShowBorder) private var pinShowBorder: Bool
    @AppStorage(.outputScaleRetinaTo1x) private var scaleRetinaTo1x: Bool
    @AppStorage(.outputAppendsRetinaSuffix) private var appendsRetinaSuffix: Bool
    @AppStorage(.pinDefaultOpacity) private var pinOpacity: Double
    @AppStorage(.outputFileNameTemplate) private var fileNamePattern: String
    @AppStorage(.outputFileNameCounter) private var fileNameCounter: Int
    @AppStorage(.outputImageFormat) private var format: ImageFormat
    @State private var confirmingClear = false
    @State private var editingFileName = false

    var body: some View {
        SettingsPageScaffold(title: SettingsPage.advanced.title) {
            SettingsCard("File name") {
                SettingsRow(
                    "File name",
                    description: FileNamePreview.fileName(pattern: fileNamePattern, format: format, counter: fileNameCounter)
                ) {
                    Button("Edit…") { editingFileName = true }
                }
                if FileNamePatternParser.usesCounter(fileNamePattern) {
                    SettingsRow("Next number", description: "Used for Number; goes up by one with every saved file.") {
                        HStack(spacing: Tokens.Spacing.xs) {
                            TextField("Next number", value: $fileNameCounter, format: .number)
                                .textFieldStyle(.roundedBorder)
                                .multilineTextAlignment(.trailing)
                                .frame(width: 64)
                            Stepper("Next number", value: $fileNameCounter, in: 0...999_999)
                        }
                    }
                }
            }
            .sheet(isPresented: $editingFileName) {
                FileNameTemplateEditor(pattern: $fileNamePattern, format: format, counter: fileNameCounter)
            }
            #if DEBUG
            .task {
                guard let url = SettingsDebug.fileNameEditorSnapshotURL else { return }
                editingFileName = true
                await SettingsDebug.snapshotSheet(to: url)
            }
            #endif

            SettingsCard("History") {
                SettingsRow("Save captures to history", description: "Browse them with Capture History… and restore closed ones.") {
                    Toggle("Save captures to history", isOn: $historyEnabled)
                        .toggleStyle(.switch)
                }
                SettingsRow("Keep history", description: "Older captures are deleted on launch and once a day.") {
                    Picker("Keep history", selection: $historyRetention) {
                        ForEach(HistoryRetention.allCases, id: \.self) { retention in
                            Text(retention.title).tag(retention)
                        }
                    }
                    .fixedSize()
                }
                .disabled(!historyEnabled)
                SettingsRow("Clear history", description: "Deletes every stored capture. Saved files are kept.") {
                    Button("Clear…") { confirmingClear = true }
                }
            }
            .confirmationDialog("Clear capture history?", isPresented: $confirmingClear) {
                Button("Clear History", role: .destructive) {
                    Task { await HistoryStore.shared.clearAll() }
                }
            } message: {
                Text("This can't be undone.")
            }

            SettingsCard("Pinned screenshots") {
                SettingsRow("Rounded corners") {
                    Toggle("Rounded corners", isOn: $pinRoundedCorners).toggleStyle(.switch)
                }
                SettingsRow("Shadow") {
                    Toggle("Shadow", isOn: $pinShowShadow).toggleStyle(.switch)
                }
                SettingsRow("Border") {
                    Toggle("Border", isOn: $pinShowBorder).toggleStyle(.switch)
                }
                SettingsRow("Opacity", description: "\(Int((pinOpacity * 100).rounded()))% for new pins. Scroll with two fingers on a pin to change it.") {
                    Slider(value: $pinOpacity, in: 0.1...1, step: 0.05)
                        .frame(width: 180)
                }
            }

            SettingsCard("Retina") {
                SettingsRow(
                    "Scale Retina screenshots to 1x",
                    description: "Save at point size instead of the native pixel grid, to shrink file size for web use."
                ) {
                    Toggle("Scale Retina screenshots to 1x", isOn: $scaleRetinaTo1x)
                        .toggleStyle(.switch)
                }
                SettingsRow(
                    "Add \u{201C}@2x\u{201D} suffix to Retina files",
                    description: "Only applies while a file is still saved at Retina resolution."
                ) {
                    Toggle("Add \u{201C}@2x\u{201D} suffix to Retina files", isOn: $appendsRetinaSuffix)
                        .toggleStyle(.switch)
                }
                .disabled(scaleRetinaTo1x)
            }
        }
    }
}
