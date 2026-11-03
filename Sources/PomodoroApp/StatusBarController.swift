import AppKit
import Observation
import PomodoroCore
import SwiftUI

@MainActor
final class StatusBarController: NSObject, NSPopoverDelegate {
    private let model: AppModel
    private let statusItem: NSStatusItem
    private let popover = NSPopover()
    private let anchorPanel: NSPanel = {
        let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.contentView = NSView()
        return panel
    }()
    private let appearance = PopoverAppearance()
    private var appearanceObservation: NSKeyValueObservation?
    private var appliedTheme: AppTheme?
    private var renderedContent: StatusItemContent?
    private var renderedLanguage: AppLanguage?
    private let quitMenuItem = NSMenuItem(title: "", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
    private var editingMenuTitles: [(NSMenuItem, String)] = []
    private var outsideClickMonitor: Any?
    private var deactivationObserver: NSObjectProtocol?
    private var dismissalID: UUID?

    init(model: AppModel) {
        self.model = model
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()
        // Keep the standard Quit shortcut available after removing the footer.
        quitMenuItem.target = NSApplication.shared
        let applicationMenu = NSMenu(title: "Sessions")
        applicationMenu.addItem(quitMenuItem)
        let applicationItem = NSMenuItem(title: "Sessions", action: nil, keyEquivalent: "")
        applicationItem.submenu = applicationMenu
        let mainMenu = NSMenu()
        mainMenu.addItem(applicationItem)
        addEditingMenu(to: mainMenu)
        NSApplication.shared.mainMenu = mainMenu
        popover.delegate = self
        popover.hasFullSizeContent = true
        popover.behavior = .transient
        popover.animates = !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        observeTheme()
        appearanceObservation = NSApplication.shared.observe(\.effectiveAppearance, options: [.new]) { [weak self] _, _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.applyAppearance(self.model.engine.settings.theme)
            }
        }
        resizePopover()
        if let button = statusItem.button {
            button.target = self
            button.action = #selector(handleStatusItemClick)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
            button.imagePosition = .imageLeading
        }
        model.onNotificationOpened = { [weak self] in self?.showPopover() }
        updateStatusItem()
    }

    isolated deinit {
        if let outsideClickMonitor { NSEvent.removeMonitor(outsideClickMonitor) }
        if let deactivationObserver { NotificationCenter.default.removeObserver(deactivationObserver) }
    }

    func showPopover() {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.contentViewController?.view.window?.makeKey()
            return
        }
        model.send(.tick(recovering: false))
        popover.animates = !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        NSApplication.shared.activate(ignoringOtherApps: true)
        if !popover.isShown, let buttonWindow = button.window, let anchor = anchorPanel.contentView {
            resizePopover()
            // The status button moves as its title changes. Snapshot its screen
            // rectangle into a separate stationary host for this presentation.
            let rect = buttonWindow.convertToScreen(button.convert(button.bounds, to: nil))
            anchorPanel.setFrame(rect, display: false)
            anchorPanel.orderFrontRegardless()
            popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .minY)
        }
        popover.contentViewController?.view.window?.makeKey()
    }

    private func addEditingMenu(to mainMenu: NSMenu) {
        let root = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        let menu = NSMenu()
        root.submenu = menu
        mainMenu.addItem(root)
        editingMenuTitles.append((root, "Правка"))

        // A nil target routes editing commands to the active field editor.
        func add(_ title: String, action: Selector, key: String,
                 modifiers: NSEvent.ModifierFlags = [.command]) {
            let item = menu.addItem(withTitle: title, action: action, keyEquivalent: key)
            item.keyEquivalentModifierMask = modifiers
            editingMenuTitles.append((item, title))
        }
        add("Отменить", action: Selector(("undo:")), key: "z")
        add("Повторить", action: Selector(("redo:")), key: "z", modifiers: [.command, .shift])
        menu.addItem(.separator())
        add("Вырезать", action: #selector(NSText.cut(_:)), key: "x")
        add("Копировать", action: #selector(NSText.copy(_:)), key: "c")
        add("Вставить", action: #selector(NSText.paste(_:)), key: "v")
        add("Удалить", action: #selector(NSText.delete(_:)), key: "")
        menu.addItem(.separator())
        add("Выделить всё", action: #selector(NSText.selectAll(_:)), key: "a")
    }

    func popoverWillShow(_ notification: Notification) {
        // Native safe-area insets are available once the popover has a window.
        // Keep the usable content size while the background fills that window.
        let animates = popover.animates
        popover.animates = false
        resizePopover()
        popover.animates = animates
        startDismissalObservers()
    }

    func popoverWillClose(_ notification: Notification) {
        stopDismissalObservers()
    }

    func popoverDidClose(_ notification: Notification) {
        anchorPanel.orderOut(nil)
    }

    private func startDismissalObservers() {
        guard dismissalID == nil else { return }
        let id = UUID()
        dismissalID = id
        let dismiss: @Sendable () -> Void = { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.dismissalID == id else { return }
                self.popover.close()
            }
        }
        // Other applications' mouse clicks are outside this popover. Own-process
        // clicks (including Picker menus and the status button) keep their routing.
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { _ in dismiss() }
        deactivationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification, object: NSApplication.shared,
            queue: .main) { _ in dismiss() }
    }

    private func stopDismissalObservers() {
        dismissalID = nil
        if let outsideClickMonitor {
            NSEvent.removeMonitor(outsideClickMonitor)
            self.outsideClickMonitor = nil
        }
        if let deactivationObserver {
            NotificationCenter.default.removeObserver(deactivationObserver)
            self.deactivationObserver = nil
        }
    }

    func popoverShouldClose(_ popover: NSPopover) -> Bool {
        // Let the status button's action toggle the window itself. Otherwise a
        // transient outside-click dismissal could close and immediately reopen it.
        guard let event = NSApp.currentEvent,
              event.type == .leftMouseDown || event.type == .rightMouseDown,
              let button = statusItem.button, event.window == button.window else { return true }
        return !button.bounds.contains(button.convert(event.locationInWindow, from: nil))
    }

    private func resizePopover() {
        let screen = statusItem.button?.window?.screen ?? NSScreen.main
        let availableHeight = screen?.visibleFrame.height ?? PomodoroStyle.panelHeight + 40
        let height = min(PomodoroStyle.panelHeight, max(1, availableHeight - 40))
        let insets = popover.contentViewController?.view.safeAreaInsets ?? NSEdgeInsets()
        let size = NSSize(width: PomodoroStyle.panelWidth + insets.left + insets.right,
                          height: height + insets.top + insets.bottom)
        popover.contentSize = size
        if popover.contentViewController == nil {
            popover.contentViewController = NSHostingController(
                rootView: PopoverView(model: model, appearance: appearance)
                    .onExitCommand { [weak self] in self?.popover.performClose(nil) })
        }
        popover.contentViewController?.view.setFrameSize(size)
    }

    private func observeTheme() {
        let theme = withObservationTracking {
            model.engine.settings.theme
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in self?.observeTheme() }
        }
        if appliedTheme != theme {
            appliedTheme = theme
            applyAppearance(theme)
        }
    }

    private func applyAppearance(_ theme: AppTheme) {
        let nativeAppearance: NSAppearance?
        switch theme {
        case .system:
            // A nil popover appearance defaults to Vibrant Light. Forward the
            // application's live appearance instead, without changing the menu bar.
            nativeAppearance = NSApplication.shared.effectiveAppearance
        case .light:
            nativeAppearance = NSAppearance(named: .aqua)
        case .dark:
            nativeAppearance = NSAppearance(named: .darkAqua)
        }
        popover.appearance = nativeAppearance
        appearance.colorScheme = nativeAppearance?.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? .dark : .light
    }

    @objc private func handleStatusItemClick() {
        if NSApplication.shared.currentEvent?.type == .rightMouseUp, let button = statusItem.button {
            popover.close()
            let menu = NSMenu()
            menu.addItem(quitMenuItem.copy() as! NSMenuItem)
            menu.popUp(positioning: nil, at: NSPoint(x: button.bounds.minX, y: button.bounds.maxY), in: button)
        } else if popover.isShown {
            popover.close()
        } else {
            showPopover()
        }
    }

    private func updateStatusItem() {
        let content = withObservationTracking {
            StatusItemFormatter.content(for: model.engine, at: model.now)
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in self?.updateStatusItem() }
        }
        guard let button = statusItem.button else { return }
        let previous = renderedContent
        // Keep the same optical baseline adjustment with or without an image.
        if previous?.title != content.title {
            button.attributedTitle = NSAttributedString(string: content.title, attributes: [
                .font: button.font ?? NSFont.systemFont(ofSize: NSFont.systemFontSize),
                .baselineOffset: -1
            ])
        }
        if previous?.symbolName != content.symbolName {
            button.image = content.symbolName.flatMap {
                NSImage(systemSymbolName: $0, accessibilityDescription: nil)
            }
            button.image?.isTemplate = true
        }
        if previous?.accessibilityLabel != content.accessibilityLabel {
            button.toolTip = content.accessibilityLabel
            button.setAccessibilityLabel(content.accessibilityLabel)
        }
        let language = model.engine.settings.language
        if renderedLanguage != language {
            button.setAccessibilityHelp(language.text("Открыть таймер Sessions", "Open Sessions timer"))
            quitMenuItem.title = AppStrings.text("Выйти из Sessions", language: language)
            for (item, title) in editingMenuTitles {
                item.title = AppStrings.text(title, language: language)
            }
            renderedLanguage = language
        }
        renderedContent = content
    }
}
