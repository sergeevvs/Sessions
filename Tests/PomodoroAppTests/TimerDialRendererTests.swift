import AppKit
import Testing
@testable import PomodoroApp

@MainActor
struct TimerDialRendererTests {
    @Test func longPausedCaptionWrapsWithinTwoLinesInsteadOfCrossingDial() {
        let caption = TimerDialRenderer.caption("Пауза · Длинный перерыв", color: .labelColor)
        let bounds = caption.boundingRect(with: NSSize(width: 140, height: 100),
                                           options: [.usesLineFragmentOrigin, .usesFontLeading])
        #expect(bounds.height > 14)
        #expect(bounds.height <= 30)
        #expect(bounds.width <= 140)
    }
}
