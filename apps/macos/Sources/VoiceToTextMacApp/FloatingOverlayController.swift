import AppKit
import Combine
import SwiftUI
import VoiceToTextMac

@MainActor
final class FloatingOverlayController {
    private let shellState: ShellState
    private var panel: NSPanel?
    private var cancellables: Set<AnyCancellable> = []

    init(shellState: ShellState) {
        self.shellState = shellState
        bind()
    }

    private func bind() {
        shellState.objectWillChange
            .sink { [weak self] _ in
                DispatchQueue.main.async {
                    self?.refresh()
                }
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: NSWindow.didChangeScreenNotification)
            .sink { [weak self] _ in
                self?.refresh()
            }
            .store(in: &cancellables)
    }

    private func refresh() {
        guard shellState.isFloatingOverlayVisible else {
            panel?.orderOut(nil)
            return
        }

        let panel = ensurePanel()
        panel.setFrame(frameForOverlay(), display: true)
        panel.orderFrontRegardless()
    }

    private func ensurePanel() -> NSPanel {
        if let panel {
            return panel
        }

        let panel = NSPanel(
            contentRect: frameForOverlay(),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = true
        panel.becomesKeyOnlyIfNeeded = false

        let hostingView = NSHostingView(
            rootView: FloatingDictationOverlayView()
                .environmentObject(shellState)
        )
        hostingView.setFrameSize(panel.contentRect(forFrameRect: panel.frame).size)
        panel.contentView = hostingView
        self.panel = panel
        return panel
    }

    private func frameForOverlay() -> NSRect {
        let width: CGFloat = 86
        let height: CGFloat = 46
        let screenFrame = activeScreenVisibleFrame()
        let originX = screenFrame.midX - (width / 2)
        let originY = screenFrame.minY + 42
        return NSRect(x: originX, y: originY, width: width, height: height)
    }

    private func activeScreenVisibleFrame() -> NSRect {
        let mouseLocation = NSEvent.mouseLocation
        if let screen = NSScreen.screens.first(where: { NSMouseInRect(mouseLocation, $0.frame, false) }) {
            return screen.visibleFrame
        }
        return NSScreen.main?.visibleFrame ?? NSScreen.screens.first?.visibleFrame ?? .zero
    }
}
