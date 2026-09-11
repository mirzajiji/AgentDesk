import CoreGraphics
import Foundation
import ImageIO

/// Pixel coordinates measured from the top-left of the orientation-corrected image.
public struct ImageMask: Sendable, Equatable {
    public let x: Int
    public let y: Int
    public let width: Int
    public let height: Int
    public init(x: Int, y: Int, width: Int, height: Int) {
        self.x = x; self.y = y; self.width = width; self.height = height
    }
}

/// Explicitly masked image bytes. This is not automatic secret detection or export authority.
public struct MaskedImageEvidence: Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public let context: RedactionContext
    public let width: Int
    public let height: Int
    public let maskCount: Int
    private let png: Data
    public var description: String { "<private masked image evidence>" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: ["content": description]) }
    fileprivate init(context: RedactionContext, width: Int, height: Int, maskCount: Int, png: Data) {
        self.context = context; self.width = width; self.height = height; self.maskCount = maskCount; self.png = png
    }
    public func withPNG<T>(in requested: RedactionContext, _ body: (Data) throws -> T) throws -> T {
        guard requested == context else { throw RedactionError.scopeMismatch }
        return try body(png)
    }
}

public enum ImageEvidenceRedactor {
    /// Re-rasterizes a single image into an opaque RGB PNG, excluding source metadata.
    /// Masks must cover sensitive pixels selected by the reviewer; unselected pixels remain visible.
    public static func mask(_ data: Data, regions: [ImageMask], in context: RedactionContext) throws -> MaskedImageEvidence {
        try Task.checkCancellation()
        guard !data.isEmpty, data.count <= 8_388_608, regions.count <= 256 else { throw RedactionError.sizeLimit }
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetCount(source) == 1,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              (1...8192).contains(width), (1...8192).contains(height), width * height <= 16_777_216 else {
            throw RedactionError.invalidContent
        }
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceThumbnailMaxPixelSize: max(width, height)]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary),
              (1...8192).contains(image.width), (1...8192).contains(image.height),
              image.width * image.height <= 16_777_216,
              let canvas = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
                bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { throw RedactionError.invalidContent }
        for region in regions {
            guard region.x >= 0, region.y >= 0, region.width > 0, region.height > 0,
                  region.x <= image.width, region.y <= image.height,
                  region.width <= image.width - region.x, region.height <= image.height - region.y else {
                throw RedactionError.invalidContent
            }
        }
        canvas.setFillColor(CGColor(gray: 1, alpha: 1))
        canvas.fill(CGRect(x: 0, y: 0, width: image.width, height: image.height))
        canvas.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        canvas.setShouldAntialias(false)
        canvas.setFillColor(CGColor(gray: 0, alpha: 1))
        for region in regions {
            try Task.checkCancellation()
            canvas.fill(CGRect(x: region.x, y: image.height - region.y - region.height, width: region.width, height: region.height))
        }
        let output = NSMutableData()
        guard let rendered = canvas.makeImage(),
              let destination = CGImageDestinationCreateWithData(output, "public.png" as CFString, 1, nil) else {
            throw RedactionError.invalidContent
        }
        CGImageDestinationAddImage(destination, rendered, nil)
        guard CGImageDestinationFinalize(destination), output.length <= 8_388_608 else { throw RedactionError.sizeLimit }
        try Task.checkCancellation()
        return MaskedImageEvidence(context: context, width: image.width, height: image.height, maskCount: regions.count, png: output as Data)
    }
}
