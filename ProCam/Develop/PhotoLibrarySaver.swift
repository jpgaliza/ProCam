import Foundation
import Photos
import UniformTypeIdentifiers
import os

/// Writes developed photos to the user's library using add-only access.
enum PhotoLibrarySaver {

    /// Whether to attempt attaching the original DNG negative as an `.alternatePhoto` resource.
    static var keepsOriginalDNG = true

    private static let log = Logger(subsystem: "com.procam", category: "PhotoLibrary")

    static var authorizationStatus: PHAuthorizationStatus {
        PHPhotoLibrary.authorizationStatus(for: .addOnly)
    }

    /// Requests add-only access if it has not been determined yet. Returns `true` if saving is allowed.
    @discardableResult
    static func requestAuthorizationIfNeeded() async -> Bool {
        var status = authorizationStatus
        if status == .notDetermined {
            status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        }
        return status == .authorized || status == .limited
    }

    static func save(_ photo: DevelopedPhoto, originalDNG: Data?) async throws {
        guard await requestAuthorizationIfNeeded() else { throw CameraError.photoLibraryDenied }

        if keepsOriginalDNG, let dng = originalDNG {
            do {
                try await savePaired(photo: photo, dng: dng)
                return
            } catch {
                // PhotoKit (error 3300 / PHPhotosErrorChangeNotSupported) can reject pairing a
                // custom Core Image-encoded HEIC with a camera DNG on some iOS versions.
                // Fall back to saving the developed photo so the shot is never lost.
                log.notice("RAW+HEIC pair rejected (\(error.localizedDescription, privacy: .public)); saving developed photo.")
            }
        }

        try await saveSingle(photo: photo)
    }

    private static func saveSingle(photo: DevelopedPhoto) async throws {
        try await PHPhotoLibrary.shared().performChanges {
            let request = PHAssetCreationRequest.forAsset()
            request.addResource(with: .photo, data: photo.data, options: nil)
        }
    }

    private static func savePaired(photo: DevelopedPhoto, dng: Data) async throws {
        // PhotoKit requires the .alternatePhoto DNG to be supplied via a file URL (passing both
        // resources as in-memory Data fails with PHPhotosErrorChangeNotSupported / 3300).
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("dng")
        try dng.write(to: tempURL, options: .atomic)
        defer { try? FileManager.default.removeItem(at: tempURL) }

        try await PHPhotoLibrary.shared().performChanges {
            let request = PHAssetCreationRequest.forAsset()
            request.addResource(with: .photo, data: photo.data, options: nil)

            let rawOptions = PHAssetResourceCreationOptions()
            rawOptions.shouldMoveFile = true
            rawOptions.uniformTypeIdentifier = UTType.dngIdentifier
            request.addResource(with: .alternatePhoto, fileURL: tempURL, options: rawOptions)
        }
    }
}

extension UTType {
    /// Adobe DNG UTI. (`UTType.dng` is iOS 18+; the identifier itself works on iOS 17.)
    static let dngIdentifier = "com.adobe.raw-image"
}
