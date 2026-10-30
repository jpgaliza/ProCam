import SwiftUI

@main
struct ProCamApp: App {

    init() {
        // Warm up Metal, the shared CIContext and bake all LUTs off the main thread so the first
        // viewfinder frame isn't delayed.
        DispatchQueue.global(qos: .userInitiated).async {
            _ = RenderContext.shared
            _ = LUTLibrary.shared
        }
    }

    var body: some Scene {
        WindowGroup {
            CameraView()
        }
    }
}
