import AVFoundation

/// A finished single-frame Bayer RAW capture, ready for development.
struct RAWCapture {
    let id: Int64
    let preset: ColorPreset
    /// DNG container produced by `AVCapturePhoto.fileDataRepresentation()`.
    let dngData: Data
    let metadata: [String: Any]
}

/// Per-capture `AVCapturePhotoCaptureDelegate`.
///
/// One instance exists per shutter press. `CameraManager` retains it until
/// `didFinishCaptureFor` fires and then releases it (AVFoundation holds delegates *weakly*).
/// AVFoundation invokes these callbacks serially on its own queue, so the mutable state below
/// needs no extra synchronization.
final class PhotoCaptureProcessor: NSObject, AVCapturePhotoCaptureDelegate {

    let id: Int64
    let preset: ColorPreset

    private let onShutter: (Int64) -> Void
    private let completion: (PhotoCaptureProcessor, Result<RAWCapture, Error>) -> Void

    private var dngData: Data?
    private var metadata: [String: Any] = [:]
    private var processingError: Error?

    init(
        id: Int64,
        preset: ColorPreset,
        onShutter: @escaping (Int64) -> Void,
        completion: @escaping (PhotoCaptureProcessor, Result<RAWCapture, Error>) -> Void
    ) {
        self.id = id
        self.preset = preset
        self.onShutter = onShutter
        self.completion = completion
    }

    func photoOutput(_ output: AVCapturePhotoOutput, willCapturePhotoFor resolvedSettings: AVCaptureResolvedPhotoSettings) {
        onShutter(id)
    }

    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        if let error {
            processingError = error
            return
        }
        // We only request RAW, but guard anyway so a processed proxy can never sneak in.
        guard photo.isRawPhoto else { return }
        guard let data = photo.fileDataRepresentation() else {
            processingError = CameraError.captureFailed("The sensor returned no RAW data.")
            return
        }
        dngData = data
        metadata = photo.metadata
    }

    func photoOutput(_ output: AVCapturePhotoOutput, didFinishCaptureFor resolvedSettings: AVCaptureResolvedPhotoSettings, error: Error?) {
        if let error = error ?? processingError {
            completion(self, .failure(error))
        } else if let dngData {
            completion(self, .success(RAWCapture(id: id, preset: preset, dngData: dngData, metadata: metadata)))
        } else {
            completion(self, .failure(CameraError.captureFailed("No RAW photo was delivered.")))
        }
        dngData = nil
    }
}
