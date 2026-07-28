import Foundation
import ImageIO
import UIKit

struct PreparedImageAttachment: Sendable, Equatable {
    let dataURL: String
    let encodedByteCount: Int
    let pixelWidth: Int
    let pixelHeight: Int
}

enum ImageAttachmentEncodingError: LocalizedError {
    case emptyData
    case inputTooLarge
    case unsupportedImage
    case jpegEncodingFailed
    case outputTooLarge

    var errorDescription: String? {
        switch self {
        case .emptyData:
            return L10n.text("ui.image_content_is_empty")
        case .inputTooLarge:
            return L10n.text("ui.the_original_image_exceeds_50_mb_please_crop")
        case .unsupportedImage:
            return L10n.text("ui.image_format_cannot_be_read")
        case .jpegEncodingFailed:
            return L10n.text("ui.image_compression_failed")
        case .outputTooLarge:
            return L10n.text("ui.the_image_still_exceeds_2_mb_after_compression")
        }
    }
}

enum ImageAttachmentEncoder {
    static let maximumInputByteCount = 50 * 1_024 * 1_024
    static let maximumPixelDimension = 1_600
    static let targetEncodedByteCount = 2 * 1_024 * 1_024

    nonisolated static func prepare(_ data: Data) throws -> PreparedImageAttachment {
        guard !data.isEmpty else {
            throw ImageAttachmentEncodingError.emptyData
        }
        guard data.count <= maximumInputByteCount else {
            throw ImageAttachmentEncodingError.inputTooLarge
        }
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
            throw ImageAttachmentEncodingError.unsupportedImage
        }

        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maximumPixelDimension,
            kCGImageSourceShouldCacheImmediately: true
        ]
        guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            throw ImageAttachmentEncodingError.unsupportedImage
        }

        let size = CGSize(width: thumbnail.width, height: thumbnail.height)
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        format.opaque = true
        let normalized = UIGraphicsImageRenderer(size: size, format: format).image { context in
            // JPEG 不支持透明通道；统一白底，避免透明 PNG 转码后出现黑色背景。
            UIColor.white.setFill()
            context.fill(CGRect(origin: .zero, size: size))
            UIImage(cgImage: thumbnail).draw(in: CGRect(origin: .zero, size: size))
        }

        var encoded: Data?
        // 普通截图通常第一档就小于 2 MB；高噪声照片逐级降质量，控制 base64/WebSocket 体积。
        for quality in [0.80, 0.68, 0.56] {
            encoded = normalized.jpegData(compressionQuality: quality)
            if let encoded, encoded.count <= targetEncodedByteCount {
                break
            }
        }
        guard let encoded else {
            throw ImageAttachmentEncodingError.jpegEncodingFailed
        }
        guard encoded.count <= targetEncodedByteCount else {
            throw ImageAttachmentEncodingError.outputTooLarge
        }

        return PreparedImageAttachment(
            dataURL: "data:image/jpeg;base64,\(encoded.base64EncodedString())",
            encodedByteCount: encoded.count,
            pixelWidth: thumbnail.width,
            pixelHeight: thumbnail.height
        )
    }
}
