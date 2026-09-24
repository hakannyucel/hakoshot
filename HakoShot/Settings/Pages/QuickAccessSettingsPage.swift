import SwiftUI

struct QuickAccessSettingsPage: View {
    @AppStorage(.quickAccessPosition) private var position: QuickAccessPosition
    @AppStorage(.quickAccessMoveToActiveScreen) private var moveToActiveScreen: Bool
    @AppStorage(.quickAccessCardWidth) private var cardWidth: Double
    @AppStorage(.quickAccessAutoCloseEnabled) private var autoCloseEnabled: Bool
    @AppStorage(.quickAccessAutoCloseSeconds) private var autoCloseSeconds: Int
    @AppStorage(.quickAccessAutoCloseAction) private var autoCloseAction: QuickAccessAutoCloseAction
    @AppStorage(.quickAccessCloseAfterDragging) private var closeAfterDragging: Bool
    @AppStorage(.quickAccessSaveBehavior) private var saveBehavior: QuickAccessSaveBehavior

    var body: some View {
        SettingsPageScaffold(title: SettingsPage.quickAccess.title) {
            SettingsCard("Overlay") {
                SettingsRow("Position on screen") {
                    Picker("Position on screen", selection: $position) {
                        Text("Left").tag(QuickAccessPosition.left)
                        Text("Right").tag(QuickAccessPosition.right)
                    }
                    .pickerStyle(.segmented)
                    .fixedSize()
                }
                SettingsRow("Move to active screen", description: "Show the overlay on the screen with the pointer.") {
                    Toggle("Move to active screen", isOn: $moveToActiveScreen)
                        .toggleStyle(.switch)
                }
                SettingsRow("Overlay size", description: "\(Int(cardWidth)) pt wide") {
                    Slider(
                        value: $cardWidth,
                        in: Double(QuickAccessConfig.cardWidthRange.lowerBound)...Double(QuickAccessConfig.cardWidthRange.upperBound),
                        step: 10
                    )
                    .frame(width: 180)
                }
            }

            SettingsCard("Auto-close") {
                SettingsRow("Close automatically", description: "Hovering the overlay pauses the timer.") {
                    Toggle("Close automatically", isOn: $autoCloseEnabled)
                        .toggleStyle(.switch)
                }
                SettingsRow("Action") {
                    Picker("Action", selection: $autoCloseAction) {
                        Text("Save and Close").tag(QuickAccessAutoCloseAction.saveAndClose)
                        Text("Close").tag(QuickAccessAutoCloseAction.close)
                    }
                    .fixedSize()
                }
                .disabled(!autoCloseEnabled)
                SettingsRow("Interval", description: "\(autoCloseSeconds) seconds") {
                    Stepper(
                        "Interval",
                        value: $autoCloseSeconds,
                        in: QuickAccessConfig.autoCloseSecondsRange,
                        step: 5
                    )
                }
                .disabled(!autoCloseEnabled)
            }

            SettingsCard("Behavior") {
                SettingsRow("Close after dragging", description: "Close the overlay once it was dropped into another app.") {
                    Toggle("Close after dragging", isOn: $closeAfterDragging)
                        .toggleStyle(.switch)
                }
                SettingsRow("Save button") {
                    Picker("Save button", selection: $saveBehavior) {
                        Text("Save to export location").tag(QuickAccessSaveBehavior.exportLocation)
                        Text("Ask for destination").tag(QuickAccessSaveBehavior.askForDestination)
                    }
                    .fixedSize()
                }
            }
        }
    }
}
