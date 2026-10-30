import AVFoundation
import Observation
import SwiftUI

/// Main-actor state for the camera screen. Bridges `CameraManager`'s event stream into SwiftUI.
@MainActor
@Observable
final class CameraViewModel {

    enum Phase: Equatable {
        case idle
        case requestingPermission
        case running
        case cameraDenied
        case failed(String)
    }

    private(set) var phase: Phase = .idle
    private(set) var processingCount = 0
    private(set) var lastThumbnail: UIImage?
    private(set) var shutterTrigger = 0        // increments on each shutter (haptic + blink)
    private(set) var savedTrigger = 0          // increments when a photo lands in the library
    private(set) var frameRate: Double = 0
    private(set) var rawAvailable = true
    private(set) var interruptionReason: String?
    private(set) var banner: String?
    private(set) var focusPoint: CGPoint?
    private(set) var focusTrigger = 0

    var selectedPreset: ColorPreset = .naturalFilm {
        didSet { camera.preset = selectedPreset }
    }

    var canCapture: Bool {
        phase == .running && rawAvailable && interruptionReason == nil
            && processingCount < CameraManager.maxCapturesInFlight
    }

    @ObservationIgnored let camera = CameraManager()
    @ObservationIgnored private var eventsTask: Task<Void, Never>?
    @ObservationIgnored private var bannerTask: Task<Void, Never>?

    init() {
        camera.preset = selectedPreset
        let stream = camera.events
        eventsTask = Task { [weak self] in
            for await event in stream {
                guard let self else { return }
                self.handle(event)
            }
        }
    }

    // MARK: Lifecycle

    func start() async {
        guard phase == .idle else { return }
        phase = .requestingPermission
        guard await CameraManager.requestCameraAccess() else {
            phase = .cameraDenied
            return
        }
        do {
            try await camera.prepareAndStart()
            phase = .running
        } catch {
            phase = .failed(error.localizedDescription)
            return
        }
        // Ask for library access up-front so the first shot isn't interrupted by a prompt.
        if !(await PhotoLibrarySaver.requestAuthorizationIfNeeded()) {
            showBanner(CameraError.photoLibraryDenied.localizedDescription, duration: 6)
        }
    }

    func handleScenePhase(_ scenePhase: ScenePhase) {
        switch scenePhase {
        case .active:
            if phase == .running { camera.start() }
        case .background:
            camera.stop()
        default:
            break
        }
    }

    // MARK: Intents

    func capture() {
        guard canCapture else { return }
        camera.capturePhoto()
    }

    func focus(at viewPoint: CGPoint, in viewSize: CGSize) {
        guard phase == .running,
              let devicePoint = camera.previewRenderer.devicePoint(forViewPoint: viewPoint, viewSize: viewSize)
        else { return }
        camera.focusAndExpose(at: devicePoint)
        focusPoint = viewPoint
        focusTrigger += 1
    }

    func openPhotosApp() {
        guard let url = URL(string: "photos-redirect://") else { return }
        UIApplication.shared.open(url)
    }

    func openSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }

    // MARK: Events

    private func handle(_ event: CameraEvent) {
        switch event {
        case .sessionRunningChanged:
            break
        case .configured(let fps, let raw):
            frameRate = fps
            rawAvailable = raw
        case .sessionInterrupted(let reason):
            interruptionReason = reason ?? "Camera interrupted"
        case .sessionInterruptionEnded:
            interruptionReason = nil
        case .captureBegan:
            processingCount += 1
        case .shutterFired:
            shutterTrigger += 1
        case .captureSaved(_, let thumbnail):
            processingCount = max(0, processingCount - 1)
            if let thumbnail { lastThumbnail = thumbnail }
            savedTrigger += 1
        case .captureFailed(_, let message):
            processingCount = max(0, processingCount - 1)
            showBanner(message)
        case .error(let message):
            showBanner(message)
        }
    }

    private func showBanner(_ message: String, duration: TimeInterval = 4) {
        banner = message
        bannerTask?.cancel()
        bannerTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(duration))
            guard !Task.isCancelled else { return }
            self?.banner = nil
        }
    }
}
