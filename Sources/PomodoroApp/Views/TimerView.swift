import PomodoroCore
import SwiftUI

struct TimerView: View {
    let model: AppModel
    private func t(_ text: String) -> String { AppStrings.text(text, language: model.engine.settings.language) }
    @Environment(\.colorSchemeContrast) private var contrast

    private var state: TimerState { model.engine.state }
    private var resetsCurrentPhase: Bool { state.status == .running || state.status == .paused }
    private var canGoBack: Bool { state.phase != .work || state.completedSessions > 0 }
    private var actionTitle: String {
        switch state.status {
        case .running: t("Пауза")
        case .paused: t("Продолжить")
        case .waiting, .ready, .dayComplete: t("Начать")
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            TimerDialView(model: model).frame(maxWidth: .infinity, minHeight: 175, maxHeight: .infinity)
            sessions.padding(.top, 7).padding(.bottom, 14)
            VStack(spacing: 8) {
                GlassActionButton(title: actionTitle,
                                  systemImage: state.status == .running ? "pause" : "play",
                                  prominent: true) {
                    model.send(state.status == .running ? .pause : .start)
                }
                .keyboardShortcut(.space, modifiers: [])

                HStack(spacing: 8) {
                    GlassActionButton(title: t(resetsCurrentPhase ? "Перезапуск" : "Назад"),
                                      systemImage: resetsCurrentPhase ? "arrow.counterclockwise" : "backward.end") {
                        model.send(.reset)
                    }
                    .help(t(resetsCurrentPhase ? "Вернуть полную длительность текущего этапа"
                            : "Вернуться к предыдущему этапу"))
                    .disabled(!resetsCurrentPhase && !canGoBack)
                    GlassActionButton(title: t("Пропустить"), systemImage: "forward.end") {
                        model.send(.skip)
                    }
                    .help(t("Перейти к следующему этапу и обновить прогресс"))
                }
            }
        }
    }

    private var sessions: some View {
        VStack(spacing: 8) {
            HStack {
                Text(t("Сессии"))
                Spacer(minLength: 8)
                Text(StatusItemFormatter.formattedProgress(completed: state.completedSessions,
                                                           goal: model.engine.settings.dailyGoal, language: model.engine.settings.language))
                    .monospacedDigit().fontWeight(.medium)
            }
            .font(.system(size: 11))
            .foregroundStyle(PomodoroStyle.secondary)
            HStack(spacing: 5) {
                ForEach(0..<model.engine.settings.dailyGoal, id: \.self) { index in
                    RoundedRectangle(cornerRadius: 3)
                        .fill(index < state.completedSessions ? PomodoroStyle.accent
                              : contrast == .increased ? PomodoroStyle.secondary.opacity(0.5) : PomodoroStyle.track)
                        .frame(maxWidth: .infinity)
                }
            }
            .frame(height: 5)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(t("Сессии"))
        .accessibilityValue(StatusItemFormatter.formattedProgress(completed: state.completedSessions,
                                                                goal: model.engine.settings.dailyGoal, language: model.engine.settings.language))
    }
}
