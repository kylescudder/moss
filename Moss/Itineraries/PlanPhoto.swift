import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Small, bounded attachments travel with the plan through the account's existing
/// encrypted transport, offline queue, RLS and sharing streams. No public URLs.
struct PlanPhoto: Codable, Identifiable, Hashable, Sendable {
    static let maximumCount = 3
    static let maximumBytes = 120_000
    let id: UUID
    let jpeg: Data

    enum CodingKeys: String, CodingKey { case id, jpeg }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id.uuidString.lowercased(), forKey: .id)
        try container.encode(jpeg, forKey: .jpeg)
    }

    static func decode(_ json: String?) -> [PlanPhoto] {
        guard let data = json?.data(using: .utf8),
              let photos = try? JSONDecoder().decode([PlanPhoto].self, from: data) else { return [] }
        return photos
    }

    static func encode(_ photos: [PlanPhoto]) throws -> String {
        guard photos.count <= maximumCount,
              Set(photos.map(\.id)).count == photos.count,
              photos.allSatisfy({ !$0.jpeg.isEmpty && $0.jpeg.count <= maximumBytes }) else {
            throw PhotoError.invalidImage
        }
        return String(decoding: try JSONEncoder().encode(photos), as: UTF8.self)
    }

    /// ImageIO bounds decoded memory, applies orientation, and exports fresh JPEG
    /// pixels without copying the source's GPS/EXIF metadata.
    static func prepare(_ data: Data) throws -> PlanPhoto {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { throw PhotoError.invalidImage }
        for dimension in [1600, 1200, 900, 640] {
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: dimension,
                kCGImageSourceShouldCacheImmediately: true,
            ]
            guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
                throw PhotoError.invalidImage
            }
            for quality in [0.8, 0.6, 0.4] {
                let output = NSMutableData()
                guard let destination = CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil) else {
                    throw PhotoError.invalidImage
                }
                CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
                if CGImageDestinationFinalize(destination), output.length <= maximumBytes {
                    return PlanPhoto(id: UUID(), jpeg: output as Data)
                }
            }
        }
        throw PhotoError.invalidImage
    }

    enum PhotoError: LocalizedError {
        case invalidImage
        var errorDescription: String? { "This photo couldn't be added. Try a different image." }
    }
}
