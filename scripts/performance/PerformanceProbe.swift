import AppKit
import Darwin
import Observation
import PomodoroCore

// Exercise the real notification service without system prompts, sounds, or alerts.
@MainActor private final class BenchmarkNotifications: NotificationBackend {
    var calls = 0
    func notificationAuthorization() async -> NotificationAuthorization { calls += 1; return .denied }
    func requestAuthorization() async throws {}
    func pendingIdentifiers() async -> [String] { calls += 1; return [] }
    func removePending(identifiers: [String]) { calls += 1 }
    func add(_ notification: ScheduledNotification, identifier: String) async throws { calls += 1 }
}

private struct Metrics {
    let cpuSeconds: Double
    let interruptWakeups: UInt64
    let residentMB: Double

    static func read() throws -> Self {
        var usage = rusage()
        guard getrusage(RUSAGE_SELF, &usage) == 0 else { throw ProbeError("getrusage failed") }
        let cpu = Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec)
            + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1_000_000
        var power = task_power_info()
        var count = mach_msg_type_number_t(MemoryLayout<task_power_info>.size / MemoryLayout<integer_t>.size)
        let powerResult = withUnsafeMutablePointer(to: &power) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_POWER_INFO), $0, &count)
            }
        }
        var memory = mach_task_basic_info()
        count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<integer_t>.size)
        let memoryResult = withUnsafeMutablePointer(to: &memory) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        guard powerResult == KERN_SUCCESS, memoryResult == KERN_SUCCESS else { throw ProbeError("task_info failed") }
        return Self(cpuSeconds: cpu, interruptWakeups: power.task_interrupt_wakeups,
                    residentMB: Double(memory.resident_size) / 1_048_576)
    }
}

private struct Sample: Codable {
    let scenario: String
    let round: Int
    let seconds: Double
    let cpuMilliseconds: Double
    let cpuPercent: Double
    let interruptWakeupsPerSecond: Double
    let popoverClockUpdates: Int
    let engineUpdates: Int
    let notificationCalls: Int
    let residentMBBefore: Double
    let residentMBAfter: Double
}

private struct Report: Codable {
    let recordedAt: String
    let operatingSystem: String
    let processors: Int
    let configuration: String
    let samples: [Sample]
}

private struct ProbeError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

@MainActor private final class PerformanceProbe {
    private let suite = "local.sessions.performance." + UUID().uuidString
    private let notifications = BenchmarkNotifications()
    private var defaults: UserDefaults!
    private var model: AppModel!
    private var controller: StatusBarController!
    private var popover: NSPopover!
    private var item: NSStatusItem!
    private var popoverClockUpdates = 0
    private var engineUpdates = 0
    private var samples: [Sample] = []
    private var seconds: Double = 15
    private var rounds = 2
    private var output: URL!

    private func observeClock() {
        withObservationTracking { _ = model.now } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.popoverClockUpdates += 1
                self.observeClock()
            }
        }
    }

    private func observeEngine() {
        withObservationTracking { _ = model.engine } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.engineUpdates += 1
                self.observeEngine()
            }
        }
    }

    private func wait(_ duration: Double) async throws { try await Task.sleep(for: .seconds(duration)) }

    private func measure(_ name: String, running: Bool, shown: Bool) async throws {
        try await wait(2) // Exclude launch, focus changes, animations and deferred layout.
        for round in 1...rounds {
            guard (model.engine.state.status == .running) == running, popover.isShown == shown else {
                throw ProbeError("\(name): unexpected timer or popover state before measurement")
            }
            popoverClockUpdates = 0
            engineUpdates = 0
            notifications.calls = 0
            let start = try Metrics.read()
            let stamp = ProcessInfo.processInfo.systemUptime
            print("MEASURING \(name) round=\(round) pid=\(ProcessInfo.processInfo.processIdentifier)")
            fflush(nil)
            try await wait(seconds)
            let end = try Metrics.read()
            let elapsed = ProcessInfo.processInfo.systemUptime - stamp
            guard (model.engine.state.status == .running) == running, popover.isShown == shown else {
                throw ProbeError("\(name): state changed during measurement; keep the probe window open and rerun")
            }
            let used = end.cpuSeconds - start.cpuSeconds
            let sample = Sample(scenario: name, round: round, seconds: elapsed,
                cpuMilliseconds: used * 1000, cpuPercent: used / elapsed * 100,
                interruptWakeupsPerSecond: Double(end.interruptWakeups - start.interruptWakeups) / elapsed,
                popoverClockUpdates: popoverClockUpdates, engineUpdates: engineUpdates,
                notificationCalls: notifications.calls, residentMBBefore: start.residentMB, residentMBAfter: end.residentMB)
            samples.append(sample)
            print(String(format: "%@ #%d: CPU %.4f%%, interrupt wakeups/s %.3f, popover clock updates %d, RSS %.2f MB",
                         name, round, sample.cpuPercent, sample.interruptWakeupsPerSecond,
                         sample.popoverClockUpdates, sample.residentMBAfter))
            fflush(nil)
            try saveReport()
        }
    }

    private func saveReport() throws {
        let report = Report(recordedAt: ISO8601DateFormatter().string(from: Date()),
            operatingSystem: ProcessInfo.processInfo.operatingSystemVersionString,
            processors: ProcessInfo.processInfo.processorCount, configuration: "Swift release, -O, native AppKit/SwiftUI UI",
            samples: samples)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(report).write(to: output, options: .atomic)
    }

    private func show() {
        popover.behavior = .applicationDefined
        controller.showPopover()
        controller.suspendDismissalForPerformanceProbe()
    }
    private func close() { popover.animates = false; popover.close() }

    func run() async -> Int32 {
        defer {
            if let item { NSStatusBar.system.removeStatusItem(item) }
            defaults?.removePersistentDomain(forName: suite)
        }
        do {
            var args = Array(CommandLine.arguments.dropFirst())
            while !args.isEmpty {
                guard args.count >= 2 else { throw ProbeError("Expected --seconds N --rounds N --output FILE") }
                let key = args.removeFirst(), value = args.removeFirst()
                switch key {
                case "--seconds": seconds = Double(value) ?? 0
                case "--rounds": rounds = Int(value) ?? 0
                case "--output": output = URL(fileURLWithPath: value)
                default: throw ProbeError("Unknown option: \(key)")
                }
            }
            guard (1...600).contains(seconds), (1...20).contains(rounds), output != nil else {
                throw ProbeError("seconds must be 1...600, rounds 1...20, and --output is required")
            }
            defaults = UserDefaults(suiteName: suite)
            guard defaults != nil else { throw ProbeError("Could not create isolated preferences") }
            model = AppModel(defaults: defaults, notifications: NotificationService(backend: notifications, soundPlayer: {}))
            controller = StatusBarController(model: model)
            let mirror = Mirror(reflecting: controller!)
            guard let popover = mirror.descendant("popover") as? NSPopover,
                  let item = mirror.descendant("statusItem") as? NSStatusItem else {
                throw ProbeError("Could not inspect the native popover/status item")
            }
            self.popover = popover
            self.item = item
            observeClock(); observeEngine()
            try await measure("hidden-idle", running: false, shown: false)
            model.send(.start)
            try await measure("hidden-running-before-open", running: true, shown: false)
            show()
            try await measure("open-running", running: true, shown: true)
            close()
            try await measure("hidden-running-after-close", running: true, shown: false)
            model.updateSettings { $0.statusItemFields = [.symbol] }
            try await measure("hidden-symbol-running", running: true, shown: false)
            model.updateSettings { $0.statusItemFields = [.time] }
            show()
            try await wait(0.5)
            guard let window = popover.contentViewController?.view.window,
                  let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.command],
                    timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                    context: nil, characters: ",", charactersIgnoringModifiers: ",", isARepeat: false, keyCode: 43),
                  window.performKeyEquivalent(with: event) else { throw ProbeError("Settings shortcut failed") }
            try await measure("settings-running", running: true, shown: true)
            _ = window.performKeyEquivalent(with: event)
            model.send(.pause)
            try await measure("open-paused", running: false, shown: true)
            close()
            try await measure("hidden-paused", running: false, shown: false)
            return 0
        } catch {
            FileHandle.standardError.write(Data("Performance probe failed: \(error)\n".utf8))
            return 1
        }
    }
}

@main private struct PerformanceMain {
    @MainActor static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        app.finishLaunching()
        let probe = PerformanceProbe()
        Task { @MainActor in exit(await probe.run()) }
        app.run()
        withExtendedLifetime(probe) {}
    }
}
