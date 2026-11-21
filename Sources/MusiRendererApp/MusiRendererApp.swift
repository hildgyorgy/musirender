import AppKit
import SwiftUI

@main
struct MusiRendererApp: App {
    @StateObject private var model = AppModel()
    @StateObject private var playerWindow = PlayerWindow()

    var body: some Scene {
        MenuBarExtra {
            StatusView(model: model, openPlayer: { playerWindow.show(model: model) })
        } label: {
            Label("MusiRenderer", systemImage: "hifispeaker.fill")
        }
        .menuBarExtraStyle(.window)

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
