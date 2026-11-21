import AppKit
import Combine
import SwiftUI

@main
struct MusiRendererApp: App {
    @NSApplicationDelegateAdaptor(MenuBarController.self) private var menuBar

    var body: some Scene {
        Settings {
            EmptyView()
        }
    }
}

@MainActor
private final class MenuBarController: NSObject, NSApplicationDelegate {
    private let model = AppModel()
    private let playerWindow = PlayerWindow()
    private let popover = NSPopover()
    private var statusItem: NSStatusItem?
    private var statusSubscription: AnyCancellable?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem = item
        guard let button = item.button else { return }
        button.target = self
        button.action = #selector(togglePopover)

        let content = NSHostingController(
            rootView: StatusView(model: model, openPlayer: { [weak self] in
                guard let self else { return }
                self.popover.close()
                self.playerWindow.show(model: self.model)
            })
        )
        content.sizingOptions = [.standardBounds, .preferredContentSize]
        content.view.setFrameSize(content.view.fittingSize)
        popover.behavior = .transient
        popover.contentViewController = content

        statusSubscription = model.$status
            .map { $0 == .online }
            .removeDuplicates()
            .sink { [weak self] isOnline in self?.updateStatusItem(isOnline: isOnline) }
    }

    private func updateStatusItem(isOnline: Bool) {
        guard let button = statusItem?.button else { return }
        let status = isOnline ? "Online" : "Offline"
        let size = NSImage.SymbolConfiguration(pointSize: 17, weight: .regular)
        let configuration = isOnline ? size.applying(.init(paletteColors: [.systemBlue])) : size
        let image = NSImage(systemSymbolName: "hifispeaker.fill", accessibilityDescription: nil)?
            .withSymbolConfiguration(configuration)
        image?.isTemplate = !isOnline
        button.image = image
        button.toolTip = status
        button.setAccessibilityLabel(RendererConfiguration.productName)
        button.setAccessibilityHelp(status)
    }

    @objc private func togglePopover() {
        guard let button = statusItem?.button else { return }
        if popover.isShown {
            popover.close()
        } else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }
    }
}

@MainActor
private final class PlayerWindow: ObservableObject {
    private var window: NSWindow?

    func show(model: AppModel) {
        if window == nil {
            let controller = NSHostingController(rootView: StatusView(model: model, openPlayer: nil))
            let window = NSWindow(contentViewController: controller)
            window.styleMask = [.titled, .closable, .miniaturizable]
            window.title = model.configuration.friendlyName
            window.isReleasedWhenClosed = false
            window.center()
            self.window = window
        }
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }
}
