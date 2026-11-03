import AppKit
import PomodoroCore
import SwiftUI

private struct SettingsTabButtonStyle: ButtonStyle {
    @Environment(\.isFocused) private var isFocused

    func makeBody(configuration: Configuration) -> some View {
        configuration.label.overlay {
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(PomodoroStyle.accent.opacity(isFocused ? 0.8 : 0), lineWidth: 2)
        }
    }
}

struct SettingsView: View {
    let model: AppModel
    private func t(_ text: String) -> String { AppStrings.text(text, language: model.engine.settings.language) }
    @State private var selectedTab = SettingsTab.cycle
    @Environment(\.colorScheme) private var colorScheme

    private var settings: PomodoroSettings { model.engine.settings }

    var body: some View {
        VStack(spacing: 13) {
            tabs
            FittingContent {
                VStack(alignment: .leading, spacing: 0) {
                    switch selectedTab {
                    case .cycle: cycleSettings
                    case .statusItem: statusItemSettings
                    case .signals: signalSettings
                    case .general: generalSettings
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .id(selectedTab)
        }
        .toggleStyle(GlassSwitchStyle())
        .font(.system(size: 11))
        .foregroundStyle(PomodoroStyle.ink)
        .tint(PomodoroStyle.accent)
    }

    private var tabs: some View {
        HStack(spacing: 3) {
            ForEach(SettingsTab.allCases) { tab in
                Button { selectedTab = tab } label: {
                    Text(t(tab.rawValue))
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(selectedTab == tab ? PomodoroStyle.ink : PomodoroStyle.secondary)
                        .frame(maxWidth: .infinity)
                        .frame(height: 27)
                        .contentShape(RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(SettingsTabButtonStyle())
                .background {
                    if selectedTab == tab {
                        RoundedRectangle(cornerRadius: 8)
                            .fill(.background.opacity(0.70))
                            .overlay {
                                RoundedRectangle(cornerRadius: 8)
                                    .strokeBorder(.white.opacity(0.65), lineWidth: 1)
                            }
                            .shadow(color: .black.opacity(0.06), radius: 1, y: 1)
                    }
                }
                .accessibilityAddTraits(selectedTab == tab ? .isSelected : [])
                .accessibilityLabel(model.engine.settings.language.text("Раздел: \(tab.rawValue)", "Section: \(t(tab.rawValue))"))
            }
        }
        .padding(3)
        .background(PomodoroStyle.track, in: RoundedRectangle(cornerRadius: 11))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(t("Раздел настроек"))
        .onMoveCommand { direction in
            let all = SettingsTab.allCases
            guard let index = all.firstIndex(of: selectedTab) else { return }
            if direction == .left { selectedTab = all[max(0, index - 1)] }
            if direction == .right { selectedTab = all[min(all.count - 1, index + 1)] }
        }
    }

    private var cycleSettings: some View {
        let summary = CycleSummary(settings: settings)
        return Group {
            VStack(alignment: .leading, spacing: 4) {
                Text("\(t("Общее время")): \(CycleSummary.formattedDuration(minutes: summary.totalMinutes, language: settings.language))")
                    .font(.system(size: 11, weight: .medium))
                Text("\(t("Работа")): \(CycleSummary.formattedDuration(minutes: summary.workMinutes, language: settings.language)) · \(t("Перерывы")): \(CycleSummary.formattedDuration(minutes: summary.breakMinutes, language: settings.language))")
                    .font(.system(size: 10))
                    .foregroundStyle(PomodoroStyle.secondary)
            }
            .padding(.vertical, 10)
            number(t("Работа"), keyPath: \.workMinutes, range: 1...180, unit: t("мин"), divided: false)
            number(t("Короткий перерыв"), keyPath: \.shortBreakMinutes, range: 1...60, unit: t("мин"))
            toggleRow(t("Длинный перерыв"), isOn: binding(\.longBreakEnabled))
                .help(t("При выключении длительность и частота длинного перерыва сохраняются."))
                .accessibilityHint(t("При выключении длительность и частота сохраняются"))
            Group {
                number(t("Длительность"), keyPath: \.longBreakMinutes, range: 1...120, unit: t("мин"),
                       accessibilityTitle: t("Длительность длинного перерыва"), indentation: 10)
                number(t("После сессий"), keyPath: \.longBreakInterval, range: 2...12, unit: "",
                       accessibilityTitle: t("Длинный перерыв после сессий"), indentation: 10)
            }
            .disabled(!settings.longBreakEnabled)
            number(t("Сессий на день"), keyPath: \.dailyGoal, range: 1...24, unit: "")
            toggleRow(t("Автопереход"), isOn: binding(\.automaticTransitions))
                .help(t("Следующий этап запускается сам. После сна таймер ждёт подтверждения."))
                .accessibilityHint(t("Следующий этап запускается сам. После сна таймер ждёт подтверждения."))
        }
    }

    private var statusItemSettings: some View {
        ForEach(StatusItemField.allCases, id: \.self) { field in
            toggleRow(fieldTitle(field), isOn: fieldBinding(field),
                      divided: field != StatusItemField.allCases.first)
                .disabled(settings.statusItemFields == [field])
                .help(t("Хотя бы один элемент значка должен оставаться включённым."))
                .accessibilityHint(settings.statusItemFields == [field]
                                   ? t("Последний выбранный элемент нельзя отключить")
                                   : t("Хотя бы один элемент должен оставаться включённым"))
        }
    }

    private var signalSettings: some View {
        Group {
            toggleRow(t("Звук"), isOn: binding(\.soundEnabled), divided: false)
                .help(t("Звук и всплывающие уведомления включаются независимо."))
            toggleRow(t("Всплывающий баннер"), isOn: binding(\.notificationsEnabled))
                .help(t("Показ зависит от разрешения macOS и режима фокусирования."))
            GlassActionButton(title: t("Проверить"), systemImage: "bell") {
                Task { await model.testNotifications() }
            }
            .disabled(!settings.soundEnabled && !settings.notificationsEnabled)
            .padding(.top, 15)
            if (settings.notificationsEnabled && model.notificationStatus != .authorized)
                || model.notificationStatus == .denied {
                Label(permissionTitle, systemImage: permissionSymbol)
                    .font(.system(size: 10)).foregroundStyle(PomodoroStyle.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 10)
            }
            if model.notificationStatus == .denied {
                GlassActionButton(title: t("Настройки уведомлений"), systemImage: "gearshape",
                                  action: openNotificationSettings)
                    .help(t("Открыть системные настройки уведомлений macOS"))
                    .accessibilityLabel(t("Открыть системные настройки уведомлений macOS"))
                    .padding(.top, 8)
            }
            integrationError
        }
    }

    private var generalSettings: some View {
        Group {
            HStack {
                Text(settings.language.text("Язык", "Language"))
                Spacer()
                Picker(settings.language.text("Язык", "Language"), selection: binding(\.language)) {
                    ForEach(AppLanguage.allCases, id: \.self) { language in
                        Text(language.nativeName).tag(language)
                    }
                }
                .labelsHidden()
                .fixedSize()
                .id(colorScheme)
            }
            .frame(minHeight: 34)
            HStack {
                Text(t("Тема"))
                Spacer()
                Picker(t("Тема"), selection: binding(\.theme)) {
                    ForEach(AppTheme.allCases, id: \.self) { theme in
                        Text(themeTitle(theme)).tag(theme)
                    }
                }
                .labelsHidden()
                .fixedSize()
                .id(colorScheme)
            }
            .frame(minHeight: 34)
            .overlay(alignment: .top) { rowDivider }
            toggleRow(t("Запускать при входе"), isOn: Binding(
                get: { model.loginItemEnabled },
                set: { model.setLaunchAtLogin($0) }))
            integrationError
        }
    }

    @ViewBuilder private var integrationError: some View {
        if let error = model.integrationError {
            Text(error).font(.caption).foregroundStyle(PomodoroStyle.error)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityLabel(settings.language.text("Ошибка: \(error)", "Error: \(error)"))
                .padding(.top, 10)
        }
    }

    private func number(_ title: String, keyPath: WritableKeyPath<PomodoroSettings, Int>,
                        range: ClosedRange<Int>, unit: String,
                        accessibilityTitle: String? = nil, indentation: CGFloat = 0,
                        divided: Bool = true) -> some View {
        IntegerSettingRow(language: settings.language, title: title, accessibilityTitle: accessibilityTitle ?? title,
                          value: binding(keyPath), range: range, unit: unit)
            .padding(.leading, indentation)
            .overlay(alignment: .top) { if divided { rowDivider } }
            .help(settings.language.text("От \(range.lowerBound) до \(range.upperBound) \(unit)", "From \(range.lowerBound) to \(range.upperBound) \(unit)")
                  + (unit == t("мин") ? settings.language.text(". Новая длительность применяется к следующему запуску, сохраняя текущий отсчёт.", ". The new duration applies at the next start, preserving the current countdown.") : ""))
    }

    private func toggleRow(_ title: String, isOn: Binding<Bool>, divided: Bool = true) -> some View {
        Toggle(title, isOn: isOn)
            .overlay(alignment: .top) { if divided { rowDivider } }
    }

    private var rowDivider: some View {
        Rectangle().fill(PomodoroStyle.line).frame(height: 0.5)
    }

    private func binding<Value>(_ keyPath: WritableKeyPath<PomodoroSettings, Value>) -> Binding<Value> {
        Binding(get: { model.engine.settings[keyPath: keyPath] },
                set: { value in model.updateSettings { $0[keyPath: keyPath] = value } })
    }

    private func fieldBinding(_ field: StatusItemField) -> Binding<Bool> {
        Binding(get: { settings.statusItemFields.contains(field) }, set: { enabled in
            model.updateSettings {
                if enabled { $0.statusItemFields.insert(field) }
                else if $0.statusItemFields.count > 1 { $0.statusItemFields.remove(field) }
            }
        })
    }

    private func fieldTitle(_ field: StatusItemField) -> String {
        switch field {
        case .symbol: t("Символ")
        case .phase: t("Этап")
        case .time: t("Время")
        case .sessions: t("Прогресс сессий")
        }
    }

    private func themeTitle(_ theme: AppTheme) -> String {
        switch theme {
        case .system: t("Системная")
        case .light: t("Светлая")
        case .dark: t("Тёмная")
        }
    }

    private var permissionTitle: String {
        switch model.notificationStatus {
        case .notDetermined: t("Разрешение macOS запрашивается при включении уведомлений, запуске таймера или проверке.")
        case .authorized: t("Уведомления разрешены macOS")
        case .denied: t("Уведомления запрещены в настройках macOS")
        }
    }

    private var permissionSymbol: String {
        model.notificationStatus == .authorized ? "checkmark.circle" : "info.circle"
    }

    private func openNotificationSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension") else { return }
        NSWorkspace.shared.open(url)
    }
}

private enum SettingsTab: String, CaseIterable, Identifiable {
    case cycle = "Цикл"
    case statusItem = "Значок"
    case signals = "Сигналы"
    case general = "Общее"

    var id: Self { self }
}

private struct IntegerSettingRow: View {
    let language: AppLanguage
    private func t(_ text: String) -> String { AppStrings.text(text, language: language) }
    let title: String
    let accessibilityTitle: String
    @Binding var value: Int
    let range: ClosedRange<Int>
    let unit: String
    @State private var draft = ""
    @FocusState private var editing: Bool
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        HStack(spacing: 7) {
            Text(title)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 3) {
                stepButton(t("Уменьшить"), symbol: "minus", disabled: value <= range.lowerBound) {
                    value = max(range.lowerBound, value - 1)
                    draft = String(value)
                }
                TextField(title, text: $draft)
                    .labelsHidden().multilineTextAlignment(.center)
                    .textFieldStyle(.plain).frame(width: 27, height: 23)
                    .monospacedDigit()
                    .background {
                        if editing {
                            RoundedRectangle(cornerRadius: 5).fill(.background.opacity(0.6))
                                .overlay {
                                    RoundedRectangle(cornerRadius: 5)
                                        .strokeBorder(PomodoroStyle.accent.opacity(0.6), lineWidth: 1)
                                }
                        }
                    }
                    .focused($editing)
                    .accessibilityLabel(accessibilityTitle)
                    .accessibilityHint(language.text("От \(range.lowerBound) до \(range.upperBound) \(unit)", "From \(range.lowerBound) to \(range.upperBound) \(unit)"))
                    .onChange(of: draft) { _, text in
                        let digits = String(text.filter { $0.isASCII && $0.isNumber }.prefix(3))
                        if digits != text { draft = digits }
                        if let entered = Int(digits) {
                            value = min(max(entered, range.lowerBound), range.upperBound)
                        }
                    }
                    .onSubmit { draft = String(value) }
                    .onChange(of: editing) { if !editing { draft = String(value) } }
                stepButton(t("Увеличить"), symbol: "plus", disabled: value >= range.upperBound) {
                    value = min(range.upperBound, value + 1)
                    draft = String(value)
                }
            }
            .fixedSize(horizontal: true, vertical: false)
            Text(unit)
                .font(.system(size: 10))
                .foregroundStyle(PomodoroStyle.secondary.opacity(isEnabled ? 1 : PomodoroStyle.disabledOpacity))
                .frame(width: 22, alignment: .leading)
        }
        .font(.system(size: 11))
        .foregroundStyle(PomodoroStyle.ink.opacity(isEnabled ? 1 : PomodoroStyle.disabledOpacity))
        .frame(minHeight: 34)
        .onAppear { draft = String(value) }
        .onChange(of: value) { if !editing { draft = String(value) } }
    }

    private func stepButton(_ actionTitle: String, symbol: String, disabled: Bool,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .medium))
        }
        .buttonStyle(PomodoroButtonStyle(height: 23, radius: 7))
        .frame(width: 23)
        .disabled(disabled)
        .accessibilityLabel("\(actionTitle): \(accessibilityTitle)")
        .accessibilityValue("\(value) \(unit)")
        .help("\(actionTitle): \(accessibilityTitle)")
    }

}
