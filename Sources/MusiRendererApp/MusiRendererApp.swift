import SwiftUI

@main
struct MusiRendererApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        MenuBarExtra {
            StatusView(model: model)
        } label: {
            Label("MusiRenderer", systemImage: "hifispeaker.fill")
        }
        .menuBarExtraStyle(.window)
    }
}
