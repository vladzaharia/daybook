import DaybookKit
import ImageIO
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// A photo from Daybook's camera: the encoded original and the moment the shutter was pressed.
struct CameraPhoto: Sendable, Equatable {
    var data: Data
    var fileExtension: String
    var capturedAt: Date

    /// HEIC (else JPEG) with the camera's metadata, kept upright by its orientation tag. The shutter
    /// moment comes from the camera's EXIF; `fallback` (when the photo was accepted) if it has none.
    static func encode(_ image: UIImage, metadata: [String: Any]?, fallback: Date) -> CameraPhoto? {
        guard let cgImage = image.cgImage else { return nil }
        var properties = metadata ?? [:]
        properties[kCGImagePropertyOrientation as String] = CGImagePropertyOrientation(image.imageOrientation).rawValue
        properties[kCGImageDestinationLossyCompressionQuality as String] = 0.85
        for (type, fileExtension) in [(UTType.heic, "heic"), (UTType.jpeg, "jpg")] {
            let output = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(output, type.identifier as CFString, 1, nil) else { continue }
            CGImageDestinationAddImage(destination, cgImage, properties as CFDictionary)
            guard CGImageDestinationFinalize(destination) else { continue }
            let data = output as Data
            return CameraPhoto(data: data, fileExtension: fileExtension, capturedAt: PhotoMetadata.read(data).capturedAt ?? fallback)
        }
        return nil
    }
}

private extension CGImagePropertyOrientation {
    init(_ orientation: UIImage.Orientation) {
        switch orientation {
        case .up: self = .up
        case .down: self = .down
        case .left: self = .left
        case .right: self = .right
        case .upMirrored: self = .upMirrored
        case .downMirrored: self = .downMirrored
        case .leftMirrored: self = .leftMirrored
        case .rightMirrored: self = .rightMirrored
        @unknown default: self = .up
        }
    }
}

/// The system camera, for still photos. Present it full screen; `finish` runs when it closes, and
/// `capture` once the photo is encoded (off the main actor), or `failed` when a photo was taken but
/// couldn't be kept, so the person hears about it rather than losing it silently.
struct CameraPicker: UIViewControllerRepresentable {
    var capture: @MainActor (CameraPhoto) -> Void
    var finish: @MainActor () -> Void
    var failed: @MainActor () -> Void = {}

    /// False in the simulator and when the camera is restricted.
    static var isAvailable: Bool { UIImagePickerController.isSourceTypeAvailable(.camera) }

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.mediaTypes = [UTType.image.identifier]
        picker.cameraCaptureMode = .photo
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ picker: UIImagePickerController, context: Context) {
        context.coordinator.parent = self
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    @MainActor
    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        var parent: CameraPicker

        init(_ parent: CameraPicker) { self.parent = parent }

        nonisolated func imagePickerController(_ picker: UIImagePickerController,
                                               didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            let accepted = Date()
            nonisolated(unsafe) let image = info[.originalImage] as? UIImage
            nonisolated(unsafe) let metadata = info[.mediaMetadata] as? [String: Any]
            MainActor.assumeIsolated {
                let capture = parent.capture, failed = parent.failed
                parent.finish()
                guard let image else { failed(); return }
                Task.detached(priority: .userInitiated) {
                    guard let photo = CameraPhoto.encode(image, metadata: metadata, fallback: accepted) else {
                        await failed()
                        return
                    }
                    await capture(photo)
                }
            }
        }

        nonisolated func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            MainActor.assumeIsolated { parent.finish() }
        }
    }
}

extension View {
    /// Daybook's camera over the whole screen while `isPresented`.
    func cameraCover(isPresented: Binding<Bool>, capture: @escaping @MainActor (CameraPhoto) -> Void,
                     failed: @escaping @MainActor () -> Void) -> some View {
        fullScreenCover(isPresented: isPresented) {
            CameraPicker(capture: capture, finish: { isPresented.wrappedValue = false }, failed: failed)
                .ignoresSafeArea()
        }
    }
}

extension PhotoOrigin {
    /// Photos from this iPhone carry the identity its recordings do, so they line up by the same clock.
    static func thisIPhone(installation: String = PhoneDevice.installationID()) -> PhotoOrigin {
        PhotoOrigin(kind: PhoneDevice.kind, serial: installation, name: UIDevice.current.name)
    }
}

extension LibraryController {
    /// A photo from Daybook's camera, placed by its shutter moment. Takes the library's lock.
    func addCameraPhoto(_ photo: CameraPhoto, to id: UUID, origin: PhotoOrigin = .thisIPhone()) async throws {
        await acquireLock()
        defer { releaseLock() }
        try await addPhoto(data: photo.data, to: id, fileName: "Photo.\(photo.fileExtension)",
                           timing: PhotoTimingInput(capturedAt: photo.capturedAt), origin: origin)
    }
}
