import AppKit
import SwiftUI

struct PopoverView: View {
    let model: AppModel
    let appearance: PopoverAppearance
    private func t(_ text: String) -> String { AppStrings.text(text, language: model.engine.settings.language) }
    @State private var showingSettings = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var navigationFocused: Bool

    var body: some View {
        content
            .foregroundStyle(PomodoroStyle.ink)
            .background {
                ZStack {
                    GlassPanelBackground()
                    Color.clear
                        .contentShape(Rectangle())
                        .onTapGesture {
                            NSApplication.shared.keyWindow?.makeFirstResponder(nil)
                        }
                }
                .ignoresSafeArea()
            }
            .environment(\.colorScheme, appearance.colorScheme)
            .onChange(of: showingSettings) { navigationFocused = true }
    }

    private var content: some View {
        VStack(spacing: 0) {
            ZStack {
                Text(showingSettings ? t("Настройки") : "Sessions")
                    .font(.system(size: 14, weight: .semibold))
                    .accessibilityAddTraits(.isHeader)
                    .padding(.horizontal, 36)
                    .frame(maxWidth: .infinity)
                HStack {
                    Spacer(minLength: 0)
                    navigationButton
                }
            }
            .frame(height: 28)

            if showingSettings {
                SettingsView(model: model)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(.top, 13)
            } else {
                FittingContent {
                    TimerView(model: model)
                }
            }

        }
        .padding(.horizontal, 17)
        .padding(.top, 17)
        .padding(.bottom, 15)
    }

    private var navigationButton: some View {
        Button {
            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.18)) {
                showingSettings.toggle()
            }
        } label: {
            Group {
                if showingSettings {
                    Image(systemName: "xmark")
                } else {
                    Image(systemName: "gearshape")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 12, height: 12)
                }
            }
            .font(.system(size: 12, weight: .regular))
            .frame(width: 16, height: 16, alignment: .center)
            .accessibilityHidden(true)
        }
        .buttonStyle(PomodoroButtonStyle(height: 28, radius: 14, emphasized: true))
        .frame(width: 28, height: 28)
        .focused($navigationFocused)
        .keyboardShortcut(",", modifiers: .command)
        .accessibilityLabel(showingSettings ? t("К таймеру") : t("Настройки"))
        .help(showingSettings ? t("К таймеру") : t("Настройки"))
    }
}
