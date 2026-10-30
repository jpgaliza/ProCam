import AVFoundation
import CoreImage
import UIKit
import os

// MARK: - Errors & events

enum CameraError: LocalizedError {
    case cameraUnavailable
    case cannotAddInput
    case cannotAddOutput
    case rawUnsupported
    case captureFailed(String)
    case developFailed(String)
    case photoLibraryDenied

    var errorDescription: String? {
        switch self {
        case .cameraUnavailable: "No back camera is available on this device."
        case .cannotAddInput: "The camera input could not be added to the capture session."
        case .cannotAddOutput: "The photo/video outputs could not be added to the capture session."
        case .rawUnsupported: "This camera format does not support Bayer RAW capture."
        case .captureFailed(let reason): "Capture failed: \(reason)"
        case .developFailed(let reason): "Development failed: \(reason)"
        case .photoLibraryDenied: "Photo library access is off. Enable it in Settings to save photos."
        }
    }
}

/// Events published by `CameraManager` (from any queue) and consumed on the main actor.
enum CameraEvent {
    case sessionRunningChanged(Bool)
    case sessionInterrupted(reason: String?)
    case sessionInterruptionEnded
    case configured(frameRate: Double, rawAvailable: Bool)
    case captureBegan(id: Int64)
    case shutterFired(id: Int64)
    case captureSaved(id: Int64, thumbnail: UIImage?)
    case captureFailed(id: Int64, message: String)
    case error(String)
}

// MARK: - CameraManager

/// Owns the `AVCaptureSession` and routes frames to the two pipelines:
///
/// ```
/// sensor ─┬─ AVCaptureVideoDataOutput ─(videoQueue)→ ColorPipeline → PreviewRenderer → MTKView
///         └─ AVCapturePhotoOutput (Bayer RAW) ─→ PhotoCaptureProcessor
///                                   ─(processingQueue)→ RAWDeveloper → PhotoLibrarySaver
/// ```
///
/// Threading contract:
/// - `sessionQueue`    – every session/device mutation and `capturePhoto`.
/// - `videoQueue`      – `captureOutput(_:didOutput:from:)` and preview rendering only.
/// - `processingQueue` – RAW development (serial: bounds peak memory to one develop at a time).
/// Public methods are safe to call from the main actor; they hop to the right queue.
final class CameraManager: NSObject, @unchecked Sendable {

    /// Maximum shots being captured/developed/saved simultaneously (memory guard: a 12 MP RAW
    /// develop holds ~100–200 MB of intermediates).
    static let maxCapturesInFlight = 2
    static let targetFrameRate: Double = 60
    /// Lower frame-rate bound. Lets auto-exposure use up to 1/30 s in low light (the RAW frame
    /// inherits the preview exposure), while bright scenes run at a locked 60 FPS.
    static let minimumFrameRate: Double = 30

    let previewRenderer = PreviewRenderer()
    let events: AsyncStream<CameraEvent>

    var preset: ColorPreset {
        get { presetState.withLock { $0 } }
        set { presetState.withLock { $0 = newValue } }
    }

    private static let log = Logger(subsystem: "com.procam", category: "Camera")

    private let eventContinuation: AsyncStream<CameraEvent>.Continuation
    private let session = AVCaptureSession()
    private let photoOutput = AVCapturePhotoOutput()
    private let videoOutput = AVCaptureVideoDataOutput()

    private let sessionQueue = DispatchQueue(label: "com.procam.session", qos: .userInitiated)
    private let videoQueue = DispatchQueue(label: "com.procam.video", qos: .userInteractive)
    private let processingQueue = DispatchQueue(label: "com.procam.processing", qos: .userInitiated)

    // sessionQueue-confined state
    private var videoDevice: AVCaptureDevice?
    private var rotationCoordinator: AVCaptureDevice.RotationCoordinator?
    private var isConfigured = false
    private var observers: [NSObjectProtocol] = []
    private var runningObservation: NSKeyValueObservation?

    // videoQueue-confined state
    private let previewPipeline = ColorPipeline()
    private var grainSeed: UInt32 = 0x9E37_79B9

    // processingQueue-confined state
    private let developer = RAWDeveloper()

    // Thread-safe state
    private let presetState = OSAllocatedUnfairLock(initialState: ColorPreset.naturalFilm)
    private struct CaptureBook {
        var delegates: [Int64: PhotoCaptureProcessor] = [:]
        var pending = 0
    }
    private let captureBook = OSAllocatedUnfairLock(uncheckedState: CaptureBook())

    override init() {
        let (stream, continuation) = AsyncStream.makeStream(of: CameraEvent.self, bufferingPolicy: .bufferingNewest(64))
        self.events = stream
        self.eventContinuation = continuation
        super.init()
    }

    deinit {
        observers.forEach(NotificationCenter.default.removeObserver)
        eventContinuation.finish()
    }

    // MARK: - Authorization

    static func requestCameraAccess() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: true
        case .notDetermined: await AVCaptureDevice.requestAccess(for: .video)
        default: false
        }
    }

    // MARK: - Lifecycle

    /// Configures the session (once) and starts it. Throws if the hardware can't be configured.
    func prepareAndStart() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            sessionQueue.async { [weak self] in
                guard let self else { return continuation.resume() }
                do {
                    try self.configureSessionIfNeeded()
                    if !self.session.isRunning { self.session.startRunning() }
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    func start() {
        sessionQueue.async { [weak self] in
            guard let self, self.isConfigured, !self.session.isRunning else { return }
            self.session.startRunning()
        }
    }

    func stop() {
        sessionQueue.async { [weak self] in
            guard let self, self.session.isRunning else { return }
            self.session.stopRunning()
        }
    }

    // MARK: - Capture

    /// Fires the shutter. Returns immediately; progress is reported through `events`.
    func capturePhoto() {
        let preset = self.preset
        sessionQueue.async { [weak self] in
            guard let self else { return }
            guard self.session.isRunning else { return }

            let admitted = self.captureBook.withLockUnchecked { book -> Bool in
                guard book.pending < Self.maxCapturesInFlight else { return false }
                book.pending += 1
                return true
            }
            guard admitted else { return }

            guard let rawFormat = self.preferredRawPixelFormat() else {
                self.captureBook.withLockUnchecked { $0.pending -= 1 }
                self.emit(.error(CameraError.rawUnsupported.localizedDescription))
                return
            }

            // Single-frame, uncompressed Bayer RAW. No processed companion → no Smart HDR /
            // Deep Fusion / multi-frame fusion is ever run on this capture.
            let settings = AVCapturePhotoSettings(rawPixelFormatType: rawFormat)
            settings.maxPhotoDimensions = self.photoOutput.maxPhotoDimensions
            if self.photoOutput.supportedFlashModes.contains(.off) { settings.flashMode = .off }

            if let connection = self.photoOutput.connection(with: .video) {
                let angle = self.rotationCoordinator?.videoRotationAngleForHorizonLevelCapture ?? 90
                if connection.isVideoRotationAngleSupported(angle) { connection.videoRotationAngle = angle }
            }

            let id = settings.uniqueID
            let processor = PhotoCaptureProcessor(
                id: id,
                preset: preset,
                onShutter: { [weak self] id in self?.emit(.shutterFired(id: id)) },
                completion: { [weak self] processor, result in self?.captureDidFinish(processor, result: result) }
            )
            self.captureBook.withLockUnchecked { $0.delegates[id] = processor }
            self.emit(.captureBegan(id: id))
            self.photoOutput.capturePhoto(with: settings, delegate: processor)
        }
    }

    private func captureDidFinish(_ processor: PhotoCaptureProcessor, result: Result<RAWCapture, Error>) {
        let id = processor.id
        captureBook.withLockUnchecked { _ = $0.delegates.removeValue(forKey: id) }

        switch result {
        case .failure(let error):
            finishCapture(id, event: .captureFailed(id: id, message: error.localizedDescription))
        case .success(let capture):
            processingQueue.async { [weak self] in
                guard let self else { return }
                let developed: DevelopedPhoto
                do {
                    developed = try autoreleasepool { try self.developer.develop(capture) }
                } catch {
                    Self.log.error("Develop failed: \(error.localizedDescription, privacy: .public)")
                    self.finishCapture(id, event: .captureFailed(id: id, message: error.localizedDescription))
                    return
                }
                let dng = capture.dngData
                Task.detached(priority: .utility) { [weak self] in
                    do {
                        try await PhotoLibrarySaver.save(developed, originalDNG: dng)
                        self?.finishCapture(id, event: .captureSaved(id: id, thumbnail: developed.thumbnail))
                    } catch {
                        self?.finishCapture(id, event: .captureFailed(id: id, message: error.localizedDescription))
                    }
                }
            }
        }
    }

    private func finishCapture(_ id: Int64, event: CameraEvent) {
        captureBook.withLockUnchecked { $0.pending = max(0, $0.pending - 1) }
        emit(event)
    }

    /// Prefer true Bayer RAW; never Apple ProRAW (which is itself a multi-frame computational output).
    private func preferredRawPixelFormat() -> OSType? {
        let formats = photoOutput.availableRawPhotoPixelFormatTypes
        return formats.first(where: { AVCapturePhotoOutput.isBayerRAWPixelFormat($0) })
            ?? formats.first(where: { !AVCapturePhotoOutput.isAppleProRAWPixelFormat($0) })
    }

    // MARK: - Focus / exposure

    /// - Parameter devicePoint: Point of interest in device space (`0...1`), see `PreviewRenderer`.
    func focusAndExpose(at devicePoint: CGPoint) {
        sessionQueue.async { [weak self] in
            self?.setFocusAndExposure(at: devicePoint, focusMode: .autoFocus, exposureMode: .autoExpose, monitorSubjectArea: true)
        }
    }

    private func setFocusAndExposure(
        at point: CGPoint,
        focusMode: AVCaptureDevice.FocusMode,
        exposureMode: AVCaptureDevice.ExposureMode,
        monitorSubjectArea: Bool
    ) {
        guard let device = videoDevice else { return }
        do {
            try device.lockForConfiguration()
            defer { device.unlockForConfiguration() }
            if device.isFocusPointOfInterestSupported, device.isFocusModeSupported(focusMode) {
                device.focusPointOfInterest = point
                device.focusMode = focusMode
            }
            if device.isExposurePointOfInterestSupported, device.isExposureModeSupported(exposureMode) {
                device.exposurePointOfInterest = point
                device.exposureMode = exposureMode
            }
            device.isSubjectAreaChangeMonitoringEnabled = monitorSubjectArea
        } catch {
            Self.log.error("Focus lock failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Session configuration (sessionQueue)

    private func configureSessionIfNeeded() throws {
        dispatchPrecondition(condition: .onQueue(sessionQueue))
        guard !isConfigured else { return }

        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) else {
            throw CameraError.cameraUnavailable
        }
        let input = try AVCaptureDeviceInput(device: device)

        session.beginConfiguration()
        session.sessionPreset = .photo
        guard session.canAddInput(input) else {
            session.commitConfiguration()
            throw CameraError.cannotAddInput
        }
        session.addInput(input)

        guard session.canAddOutput(photoOutput), session.canAddOutput(videoOutput) else {
            session.commitConfiguration()
            throw CameraError.cannotAddOutput
        }
        session.addOutput(photoOutput)
        session.addOutput(videoOutput)

        videoOutput.videoSettings = [
            // Native bi-planar YUV: zero conversion cost; Core Image samples it directly.
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
        ]
        videoOutput.alwaysDiscardsLateVideoFrames = true
        videoOutput.setSampleBufferDelegate(self, queue: videoQueue)
        session.commitConfiguration()

        let (frameRate, rawAvailable) = selectFormat(for: device)
        configurePhotoOutput(for: device)
        configureDevice(device)
        configureConnections()

        rotationCoordinator = AVCaptureDevice.RotationCoordinator(device: device, previewLayer: nil)
        videoDevice = device
        isConfigured = true
        installObservers(for: device)

        Self.log.info("Configured: \(frameRate, privacy: .public) FPS, RAW=\(rawAvailable, privacy: .public)")
        emit(.configured(frameRate: frameRate, rawAvailable: rawAvailable))
        if !rawAvailable { emit(.error(CameraError.rawUnsupported.localizedDescription)) }
    }

    private func configurePhotoOutput(for device: AVCaptureDevice) {
        // --- Disable every computational / multi-frame feature on the photo output ---
        if photoOutput.isAppleProRAWSupported { photoOutput.isAppleProRAWEnabled = false }
        photoOutput.isVirtualDeviceConstituentPhotoDeliveryEnabled = false
        if photoOutput.isLivePhotoCaptureSupported { photoOutput.isLivePhotoCaptureEnabled = false }
        if photoOutput.isDepthDataDeliverySupported { photoOutput.isDepthDataDeliveryEnabled = false }
        if photoOutput.isPortraitEffectsMatteDeliverySupported { photoOutput.isPortraitEffectsMatteDeliveryEnabled = false }
        if photoOutput.isContentAwareDistortionCorrectionSupported { photoOutput.isContentAwareDistortionCorrectionEnabled = false }
        if photoOutput.isAutoDeferredPhotoDeliverySupported { photoOutput.isAutoDeferredPhotoDeliveryEnabled = false }
        if photoOutput.isFastCapturePrioritizationSupported { photoOutput.isFastCapturePrioritizationEnabled = false }
        // Responsive capture only overlaps capture/processing of consecutive shots; it never blends frames.
        if photoOutput.isResponsiveCaptureSupported { photoOutput.isResponsiveCaptureEnabled = true }

        // Largest photo size the active format supports (Bayer RAW is the 12 MP binned readout).
        if let largest = device.activeFormat.supportedMaxPhotoDimensions.max(by: { $0.width * $0.height < $1.width * $1.height }) {
            photoOutput.maxPhotoDimensions = largest
        }
    }

    private func configureDevice(_ device: AVCaptureDevice) {
        do {
            try device.lockForConfiguration()
            defer { device.unlockForConfiguration() }

            if device.isFocusModeSupported(.continuousAutoFocus) { device.focusMode = .continuousAutoFocus }
            if device.isExposureModeSupported(.continuousAutoExposure) { device.exposureMode = .continuousAutoExposure }
            if device.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) { device.whiteBalanceMode = .continuousAutoWhiteBalance }

            // Keep the viewfinder geometry identical to the uncorrected RAW.
            if device.isGeometricDistortionCorrectionSupported { device.isGeometricDistortionCorrectionEnabled = false }
            // No video HDR / low-light boost: these are multi-frame computational modes.
            if device.activeFormat.isVideoHDRSupported {
                device.automaticallyAdjustsVideoHDREnabled = false
                device.isVideoHDREnabled = false
            }
            if device.isLowLightBoostSupported { device.automaticallyEnablesLowLightBoostWhenAvailable = false }
            device.isSubjectAreaChangeMonitoringEnabled = false
        } catch {
            Self.log.error("Device configuration failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func configureConnections() {
        guard let connection = videoOutput.connection(with: .video) else { return }
        // Stabilization crops the preview → framing would no longer match the RAW.
        if connection.isVideoStabilizationSupported { connection.preferredVideoStabilizationMode = .off }
        // Keep buffers in native sensor orientation; rotation is a free CIImage orientation tag.
        if connection.isVideoRotationAngleSupported(0) { connection.videoRotationAngle = 0 }
    }

    /// Picks a 4:3 (same framing as the RAW) YUV format that sustains 60 FPS *and* still offers
    /// Bayer RAW. Falls back to the `.photo` preset (typically 30 FPS) if none qualifies.
    private func selectFormat(for device: AVCaptureDevice) -> (frameRate: Double, rawAvailable: Bool) {
        for format in Self.rankedPreviewFormats(device.formats) {
            let frameRate = min(Self.targetFrameRate, Self.maxFrameRate(of: format))
            guard apply(format, frameRate: frameRate, to: device) else { continue }
            if preferredRawPixelFormat() != nil { return (frameRate, true) }
        }

        Self.log.notice("No 60 FPS format with Bayer RAW; falling back to the .photo preset.")
        session.beginConfiguration()
        session.sessionPreset = .photo
        session.commitConfiguration()
        let duration = device.activeVideoMinFrameDuration
        let frameRate = duration.seconds > 0 ? 1 / duration.seconds : 30
        return (frameRate.rounded(), preferredRawPixelFormat() != nil)
    }

    private func apply(_ format: AVCaptureDevice.Format, frameRate: Double, to device: AVCaptureDevice) -> Bool {
        do {
            try device.lockForConfiguration()
        } catch {
            return false
        }
        session.beginConfiguration()
        device.activeFormat = format
        let minDuration = CMTime(value: 1, timescale: CMTimeScale(frameRate))
        let lowerRate = max(Self.minimumFrameRate, Self.minFrameRate(of: format))
        let maxDuration = lowerRate < frameRate ? CMTime(value: 1, timescale: CMTimeScale(lowerRate)) : minDuration
        device.activeVideoMinFrameDuration = minDuration
        device.activeVideoMaxFrameDuration = maxDuration
        session.commitConfiguration()
        device.unlockForConfiguration()
        return true
    }

    static func rankedPreviewFormats(_ formats: [AVCaptureDevice.Format]) -> [AVCaptureDevice.Format] {
        formats
            .filter { format in
                let subtype = CMFormatDescriptionGetMediaSubType(format.formatDescription)
                let is8BitBiPlanar = subtype == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
                    || subtype == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
                guard is8BitBiPlanar else { return false }
                return maxFrameRate(of: format) >= targetFrameRate
            }
            .sorted { a, b in
                let da = CMVideoFormatDescriptionGetDimensions(a.formatDescription)
                let db = CMVideoFormatDescriptionGetDimensions(b.formatDescription)
                let is4by3A = Int(da.width) * 3 == Int(da.height) * 4
                let is4by3B = Int(db.width) * 3 == Int(db.height) * 4
                if is4by3A != is4by3B { return is4by3A }

                let pa = maxPhotoPixels(of: a), pb = maxPhotoPixels(of: b)
                if pa != pb { return pa > pb }

                let efficientA = da.width <= 2016, efficientB = db.width <= 2016
                if efficientA != efficientB { return efficientA }

                return da.width > db.width
            }
    }

    private static func maxFrameRate(of format: AVCaptureDevice.Format) -> Double {
        format.videoSupportedFrameRateRanges.map(\.maxFrameRate).max() ?? 0
    }

    private static func minFrameRate(of format: AVCaptureDevice.Format) -> Double {
        format.videoSupportedFrameRateRanges.map(\.minFrameRate).min() ?? 1
    }

    private static func maxPhotoPixels(of format: AVCaptureDevice.Format) -> Int {
        format.supportedMaxPhotoDimensions.map { Int($0.width) * Int($0.height) }.max() ?? 0
    }

    // MARK: - Observers

    private func installObservers(for device: AVCaptureDevice) {
        let center = NotificationCenter.default

        runningObservation = session.observe(\.isRunning, options: [.new]) { [weak self] _, change in
            guard let running = change.newValue else { return }
            self?.emit(.sessionRunningChanged(running))
        }

        observers.append(center.addObserver(forName: AVCaptureSession.runtimeErrorNotification, object: session, queue: nil) { [weak self] note in
            guard let self else { return }
            let error = note.userInfo?[AVCaptureSessionErrorKey] as? AVError
            Self.log.error("Session runtime error: \(String(describing: error), privacy: .public)")
            if error?.code == .mediaServicesWereReset {
                self.start()
            } else {
                self.emit(.error(error?.localizedDescription ?? "The camera stopped unexpectedly."))
            }
        })

        observers.append(center.addObserver(forName: AVCaptureSession.wasInterruptedNotification, object: session, queue: nil) { [weak self] note in
            let reason = (note.userInfo?[AVCaptureSessionInterruptionReasonKey] as? Int)
                .flatMap(AVCaptureSession.InterruptionReason.init(rawValue:))
            self?.emit(.sessionInterrupted(reason: reason.map(Self.describe)))
        })

        observers.append(center.addObserver(forName: AVCaptureSession.interruptionEndedNotification, object: session, queue: nil) { [weak self] _ in
            self?.emit(.sessionInterruptionEnded)
        })

        observers.append(center.addObserver(forName: AVCaptureDevice.subjectAreaDidChangeNotification, object: device, queue: nil) { [weak self] _ in
            guard let self else { return }
            self.sessionQueue.async {
                self.setFocusAndExposure(
                    at: CGPoint(x: 0.5, y: 0.5),
                    focusMode: .continuousAutoFocus,
                    exposureMode: .continuousAutoExposure,
                    monitorSubjectArea: false
                )
            }
        })
    }

    private static func describe(_ reason: AVCaptureSession.InterruptionReason) -> String {
        switch reason {
        case .videoDeviceNotAvailableInBackground: "Camera paused in background"
        case .audioDeviceInUseByAnotherClient, .videoDeviceInUseByAnotherClient: "Camera in use by another app"
        case .videoDeviceNotAvailableWithMultipleForegroundApps: "Camera unavailable in multitasking"
        case .videoDeviceNotAvailableDueToSystemPressure: "Camera paused: device too hot"
        default: "Camera interrupted"
        }
    }

    private func emit(_ event: CameraEvent) {
        eventContinuation.yield(event)
    }
}

// MARK: - Video frames → live graded preview

extension CameraManager: AVCaptureVideoDataOutputSampleBufferDelegate {

    /// Hot path (up to 60×/s on `videoQueue`). Rules: no filter/context/color-space creation,
    /// no locks held across GPU work, no main-thread hops. See AGENTS.md § Rules.
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        // Sensor buffers are landscape; `.right` rotates to portrait for the back camera at zero cost.
        let source = CIImage(cvPixelBuffer: pixelBuffer).oriented(.right)

        // xorshift32 → animated grain without Foundation RNG overhead.
        grainSeed ^= grainSeed << 13
        grainSeed ^= grainSeed >> 17
        grainSeed ^= grainSeed << 5

        let graded = previewPipeline.apply(preset, to: source, grainSeed: grainSeed)
        previewRenderer.render(graded)
    }
}
