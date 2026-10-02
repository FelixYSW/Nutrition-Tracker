import Foundation
import CoreVideo
import CoreGraphics
#if canImport(UIKit)
import UIKit
#endif

/// Stores retained food photos in the app container (spec section 17).
///
/// Only a *relative* path is persisted in SwiftData: the container URL changes
/// between installs and re-signs, so an absolute path would dangle after a
/// Sideloadly reinstall.
enum ImageStore {

    static let directoryName = "FoodPhotos"

    static func directoryURL() throws -> URL {
        let support = try FileManager.default.url(for: .applicationSupportDirectory,
                                                  in: .userDomainMask,
                                                  appropriateFor: nil,
                                                  create: true)
        let directory = support.appendingPathComponent(directoryName, isDirectory: true)
        if !FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.createDirectory(at: directory,
                                                    withIntermediateDirectories: true)
            // Food photos are personal data and should not go to iCloud backups
            // without the user asking, nor be indexed.
            var excluded = URLResourceValues()
            excluded.isExcludedFromBackup = true
            var mutableDirectory = directory
            try? mutableDirectory.setResourceValues(excluded)
        }
        return directory
    }

    static func url(forRelativePath path: String) -> URL? {
        guard let directory = try? directoryURL() else { return nil }
        return directory.appendingPathComponent(path)
    }

    /// Writes JPEG data and returns the relative path to persist.
    @discardableResult
    static func save(jpegData: Data, id: UUID = UUID()) throws -> String {
        let directory = try directoryURL()
        let filename = "\(id.uuidString).jpg"
        let url = directory.appendingPathComponent(filename)
        try jpegData.write(to: url, options: .atomic)
        return filename
    }

    static func load(relativePath: String) -> Data? {
        guard let url = url(forRelativePath: relativePath) else { return nil }
        return try? Data(contentsOf: url)
    }

    static func delete(relativePath: String) {
        guard let url = url(forRelativePath: relativePath) else { return }
        try? FileManager.default.removeItem(at: url)
    }

    /// Removes every retained photo. Used by "delete all data" and by turning
    /// the retain-images setting off.
    static func deleteAll() {
        guard let directory = try? directoryURL() else { return }
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil)) ?? []
        for url in contents {
            try? FileManager.default.removeItem(at: url)
        }
    }

    /// Deletes any file not referenced by a surviving entry, so turning retention
    /// off or deleting entries does not leak images.
    static func pruneOrphans(referencedPaths: Set<String>) {
        guard let directory = try? directoryURL() else { return }
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil)) ?? []
        for url in contents where !referencedPaths.contains(url.lastPathComponent) {
            try? FileManager.default.removeItem(at: url)
        }
    }
}

#if canImport(UIKit)

/// Decodes, downsizes and normalises an image exactly once before inference
/// (spec section 40).
enum ImagePreparer {

    /// Resizes so the longest edge is `targetEdge`, then produces both a
    /// pixel buffer for Core ML and JPEG bytes for storage/remote fallback.
    static func prepare(image: UIImage,
                        targetEdge: CGFloat = PreparedImage.targetEdge,
                        jpegQuality: CGFloat = 0.8) throws -> PreparedImage {
        let normalised = image.normalisedOrientation()
        let resized = normalised.resized(longestEdge: targetEdge)

        guard let jpegData = resized.jpegData(compressionQuality: jpegQuality) else {
            throw AIServiceError.invalidImage
        }
        guard let pixelBuffer = resized.pixelBuffer() else {
            throw AIServiceError.invalidImage
        }

        return PreparedImage(pixelBuffer: pixelBuffer,
                             pixelSize: resized.size,
                             jpegData: jpegData)
    }

    static func prepare(data: Data,
                        targetEdge: CGFloat = PreparedImage.targetEdge) throws -> PreparedImage {
        guard let image = UIImage(data: data) else { throw AIServiceError.invalidImage }
        return try prepare(image: image, targetEdge: targetEdge)
    }
}

extension UIImage {

    /// Bakes the EXIF orientation into the pixels. Without this, a photo taken
    /// in portrait is fed to the model rotated.
    func normalisedOrientation() -> UIImage {
        guard imageOrientation != .up else { return self }
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        return renderer.image { _ in
            draw(in: CGRect(origin: .zero, size: size))
        }
    }

    func resized(longestEdge: CGFloat) -> UIImage {
        let maxDimension = max(size.width, size.height)
        guard maxDimension > longestEdge, maxDimension > 0 else { return self }
        let scale = longestEdge / maxDimension
        let newSize = CGSize(width: (size.width * scale).rounded(),
                             height: (size.height * scale).rounded())

        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: newSize, format: format)
        return renderer.image { _ in
            draw(in: CGRect(origin: .zero, size: newSize))
        }
    }

    /// 32-bit BGRA pixel buffer, which is what Vision and Core ML image inputs
    /// expect.
    func pixelBuffer() -> CVPixelBuffer? {
        guard let cgImage else { return nil }
        let width = cgImage.width
        let height = cgImage.height
        guard width > 0, height > 0 else { return nil }

        let attributes: [CFString: Any] = [
            kCVPixelBufferCGImageCompatibilityKey: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey: true
        ]

        var buffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(kCFAllocatorDefault, width, height,
                                         kCVPixelFormatType_32BGRA,
                                         attributes as CFDictionary, &buffer)
        guard status == kCVReturnSuccess, let pixelBuffer = buffer else { return nil }

        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }

        guard let base = CVPixelBufferGetBaseAddress(pixelBuffer) else { return nil }
        let colourSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: base,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(pixelBuffer),
            space: colourSpace,
            bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue
                | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { return nil }

        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        return pixelBuffer
    }
}

#endif
