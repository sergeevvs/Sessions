import AppKit
import Observation
import PomodoroCore
import SwiftUI

/// A fixed-size drawing surface keeps a clock tick out of SwiftUI's fitting/layout graph.
struct TimerDialView: View {
    let model: AppModel

    var body: some View {
        TimerDialSurface(model: model).frame(width: 164, height: 164)
    }
}

private struct TimerDialSurface: NSViewRepresentable {
    let model: AppModel
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.colorScheme) private var colorScheme

    func makeNSView(context: Context) -> TimerDialRenderer {
        TimerDialRenderer(model: model)
    }

    func updateNSView(_ view: TimerDialRenderer, context: Context) {
        view.configure(colorScheme: colorScheme, increasedContrast: contrast == .increased)
    }
}

@MainActor
final class TimerDialRenderer: NSView {
    private let model: AppModel
    private var snapshot: TimerDialSnapshot?
    private var increasedContrast = false

    override var isFlipped: Bool { true }
    override var intrinsicContentSize: NSSize { NSSize(width: 164, height: 164) }

    init(model: AppModel) {
        self.model = model
        super.init(frame: NSRect(origin: .zero, size: NSSize(width: 164, height: 164)))
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        // Register outside SwiftUI's representable update so only this NSView
        // depends on the clock, never the surrounding ViewThatFits/ScrollView.
        Task { @MainActor [weak self] in self?.observeDisplay() }
    }

    required init?(coder: NSCoder) { nil }

    func configure(colorScheme: ColorScheme, increasedContrast: Bool) {
        let name: NSAppearance.Name = colorScheme == .dark ? .darkAqua : .aqua
        if appearance?.name != name { appearance = NSAppearance(named: name) }
        if self.increasedContrast != increasedContrast {
            self.increasedContrast = increasedContrast
            needsDisplay = true
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    private func observeDisplay() {
        let next = withObservationTracking {
            TimerDialSnapshot(engine: model.engine, now: model.now)
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in self?.observeDisplay() }
        }
        guard snapshot != next else { return }
        snapshot = next
        setAccessibilityLabel(next.accessibilityLabel)
        setAccessibilityValue(next.statusTitle)
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let snapshot, let context = NSGraphicsContext.current?.cgContext else { return }
        let accent = NSColor(PomodoroStyle.accent)
        let secondary = NSColor(PomodoroStyle.secondary)
        let track = increasedContrast ? secondary.withAlphaComponent(0.5)
            : NSColor(PomodoroStyle.track)
        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        let radius: CGFloat = 71.75
        context.setLineWidth(4.1)
        context.setStrokeColor(track.cgColor)
        context.strokeEllipse(in: CGRect(x: center.x - radius, y: center.y - radius,
                                         width: radius * 2, height: radius * 2))
        if snapshot.remainingFraction > 0 {
            context.saveGState()
            context.setStrokeColor(accent.cgColor)
            context.setLineCap(.round)
            context.setShadow(offset: .zero, blur: 3, color: accent.withAlphaComponent(0.18).cgColor)
            context.addArc(center: center, radius: radius, startAngle: -.pi / 2,
                           endAngle: -.pi / 2 + snapshot.remainingFraction * 2 * .pi, clockwise: false)
            context.strokePath()
            context.restoreGState()
        }

        let ink = NSColor(PomodoroStyle.ink)
        var time = countdown(snapshot.time, color: ink, scale: 1)
        if time.size().width > 140 {
            time = countdown(snapshot.time, color: ink, scale: max(0.7, 140 / time.size().width))
        }
        let size = time.size()
        time.draw(at: NSPoint(x: center.x - size.width / 2, y: center.y - 8 - size.height / 2))
        Self.caption(snapshot.statusTitle, color: secondary).draw(
            with: NSRect(x: center.x - 70, y: center.y + 21, width: 140, height: 30),
            options: [.usesLineFragmentOrigin, .usesFontLeading])
    }

    static func caption(_ text: String, color: NSColor) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.lineBreakMode = .byWordWrapping
        return NSAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: 11), .foregroundColor: color, .paragraphStyle: paragraph
        ])
    }

    private func countdown(_ text: String, color: NSColor, scale: CGFloat) -> NSAttributedString {
        NSAttributedString(string: text, attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 42 * scale, weight: .regular),
            .kern: -1.6 * scale, .foregroundColor: color
        ])
    }
}

private struct TimerDialSnapshot: Equatable {
    let time: String
    let remainingFraction: Double
    let statusTitle: String
    let accessibilityLabel: String

    init(engine: TimerEngine, now: Date) {
        let language = engine.settings.language
        func t(_ text: String) -> String { AppStrings.text(text, language: language) }
        let phase: String
        switch engine.state.phase {
        case .work: phase = t("Работа")
        case .shortBreak: phase = t("Короткий перерыв")
        case .longBreak: phase = t("Длинный перерыв")
        }
        time = StatusItemFormatter.formattedTime(engine.remaining(at: now))
        remainingFraction = engine.state.status == .dayComplete ? 1 : 1 - engine.progress(at: now)
        switch engine.state.status {
        case .ready, .running: statusTitle = phase
        case .paused: statusTitle = "\(t("Пауза")) · \(phase)"
        case .waiting: statusTitle = "\(phase)\n\(t("Ожидает запуска"))"
        case .dayComplete: statusTitle = t("План выполнен")
        }
        accessibilityLabel = language.text("\(phase), осталось \(time)", "\(phase), \(time) remaining")
    }
}
