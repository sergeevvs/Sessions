import PomodoroCore
import SwiftUI

/// Only the dial reads the display clock; buttons and session bars update on state changes.
struct TimerDialView: View {
    let model: AppModel
    @Environment(\.colorSchemeContrast) private var contrast
    private func t(_ text: String) -> String { AppStrings.text(text, language: model.engine.settings.language) }
    private var state: TimerState { model.engine.state }
    private var complete: Bool { state.status == .dayComplete }
    private var phaseTitle: String {
        switch state.phase {
        case .work: t("Работа")
        case .shortBreak: t("Короткий перерыв")
        case .longBreak: t("Длинный перерыв")
        }
    }
    private var time: String {
        StatusItemFormatter.formattedTime(model.engine.remaining(at: model.now))
    }
    private var statusTitle: String {
        switch state.status {
        case .ready, .running: phaseTitle
        case .paused: "\(t("Пауза")) · \(phaseTitle)"
        case .waiting: "\(phaseTitle)\n\(t("Ожидает запуска"))"
        case .dayComplete: t("План выполнен")
        }
    }

    var body: some View {
        ZStack {
            Circle().inset(by: 10.25)
                .stroke(contrast == .increased ? PomodoroStyle.secondary.opacity(0.5) : PomodoroStyle.track,
                        lineWidth: 4.1)
            Circle()
                .inset(by: 10.25)
                .trim(from: 0, to: complete ? 1 : 1 - model.engine.progress(at: model.now))
                .stroke(PomodoroStyle.accent, style: StrokeStyle(lineWidth: 4.1, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .shadow(color: PomodoroStyle.accent.opacity(0.18), radius: 3)
            // Anchor the countdown independently of the caption's line count.
            Text(time)
                .font(.system(size: 42, weight: .regular))
                .monospacedDigit()
                .tracking(-1.6)
                .contentTransition(.identity)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .frame(width: 140, height: 52)
                .offset(y: -8)
            Text(statusTitle)
                .font(.system(size: 11))
                .foregroundStyle(PomodoroStyle.secondary)
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
                .frame(width: 140, height: 30, alignment: .top)
                .offset(y: 36)
        }
        .frame(width: 164, height: 164)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(model.engine.settings.language.text("\(phaseTitle), осталось \(time)", "\(phaseTitle), \(time) remaining"))
        .accessibilityValue(statusTitle)
    }

}
