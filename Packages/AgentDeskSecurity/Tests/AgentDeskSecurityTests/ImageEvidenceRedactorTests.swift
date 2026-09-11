import AgentDeskCore
import CoreGraphics
import Foundation
import ImageIO
import XCTest
@testable import AgentDeskSecurity

final class ImageEvidenceRedactorTests: XCTestCase {
    func testMaskRemovesPixelsAndMetadataAndRejectsForeignScope() throws {
        let context = RedactionContext(scope: .init(workspaceID: WorkspaceID(), projectID: ProjectID()), environmentID: EnvironmentID(), runID: RunID())
        let source = try fixture()
        let original = try XCTUnwrap(CGImageSourceCreateWithData(source as CFData, nil))
        let originalProperties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(original, 0, nil))
        XCTAssertTrue(String(describing: originalProperties).contains("synthetic-private-metadata"))
        let result = try ImageEvidenceRedactor.mask(source, regions: [.init(x: 0, y: 0, width: 4, height: 4)], in: context)
        XCTAssertEqual(result.width, 16); XCTAssertEqual(result.height, 16)
        XCTAssertEqual(result.maskCount, 1)
        let png = try result.withPNG(in: context) { $0 }
        let decoded = try XCTUnwrap(CGImageSourceCreateWithData(png as CFData, nil))
        let properties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(decoded, 0, nil) as? [CFString: Any])
        XCTAssertFalse(String(describing: properties).contains("synthetic-private-metadata"))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(decoded, 0, nil))
        let pixels = try XCTUnwrap(image.dataProvider?.data) as Data
        let channels = image.bitsPerPixel / 8
        XCTAssertEqual(Array(pixels.prefix(3)), [0, 0, 0], "Top-left mask must affect the top-left pixels")
        XCTAssertEqual(Array(pixels[(15 * image.bytesPerRow + 15 * channels)..<(15 * image.bytesPerRow + 15 * channels + 3)]), [255, 255, 255])
        let foreign = RedactionContext(scope: context.scope, environmentID: context.environmentID, runID: RunID())
        XCTAssertThrowsError(try result.withPNG(in: foreign) { $0 })
        XCTAssertFalse(String(reflecting: result).contains("synthetic-private-metadata"))
        for region in [ImageMask(x: -1, y: 0, width: 1, height: 1), .init(x: 15, y: 0, width: 2, height: 1),
                       .init(x: 0, y: 0, width: Int.max, height: 1), .init(x: 0, y: 0, width: 0, height: 1)] {
            XCTAssertThrowsError(try ImageEvidenceRedactor.mask(source, regions: [region], in: context))
        }
        XCTAssertThrowsError(try ImageEvidenceRedactor.mask(Data("not an image".utf8), regions: [], in: context))
    }

    func testBoundsAndCancellation() async throws {
        let context = RedactionContext(scope: .init(workspaceID: WorkspaceID(), projectID: ProjectID()), environmentID: EnvironmentID(), runID: RunID())
        let source = try fixture()
        XCTAssertThrowsError(try ImageEvidenceRedactor.mask(Data(repeating: 0, count: 8_388_609), regions: [], in: context))
        XCTAssertThrowsError(try ImageEvidenceRedactor.mask(source, regions: Array(repeating: .init(x: 0, y: 0, width: 1, height: 1), count: 257), in: context))
        let operation = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try ImageEvidenceRedactor.mask(source, regions: [], in: context)
        }
        do { _ = try await operation.value; XCTFail("Cancelled image processing returned evidence") }
        catch { XCTAssertTrue(error is CancellationError) }
    }

    func testRotationMetadataIsAppliedBeforeMaskCoordinates() throws {
        let context = RedactionContext(scope: .init(workspaceID: WorkspaceID(), projectID: ProjectID()), environmentID: EnvironmentID(), runID: RunID())
        let row: [UInt8] = [255, 0, 0, 255, 255, 0, 0, 255, 0, 0, 255, 255, 0, 0, 255, 255]
        let provider = try XCTUnwrap(CGDataProvider(data: Data(row + row) as CFData))
        let image = try XCTUnwrap(CGImage(width: 4, height: 2, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: 16, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        let input = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(input, "public.tiff" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, [kCGImagePropertyOrientation: 6] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        let original = try XCTUnwrap(CGImageSourceCreateWithData(input, nil))
        let originalProperties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(original, 0, nil) as? [CFString: Any])
        XCTAssertEqual(originalProperties[kCGImagePropertyOrientation] as? Int, 6)
        let output = try ImageEvidenceRedactor.mask(input as Data, regions: [.init(x: 0, y: 0, width: 1, height: 1)], in: context)
        XCTAssertEqual(output.width, 2); XCTAssertEqual(output.height, 4)
        let png = try output.withPNG(in: context) { $0 }
        let source = try XCTUnwrap(CGImageSourceCreateWithData(png as CFData, nil))
        let rendered = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        let bytes = try XCTUnwrap(rendered.dataProvider?.data) as Data
        func pixel(_ x: Int, _ y: Int) -> [UInt8] {
            let offset = y * rendered.bytesPerRow + x * (rendered.bitsPerPixel / 8)
            return Array(bytes[offset..<(offset + 3)])
        }
        XCTAssertEqual(pixel(0, 0), [0, 0, 0])
        XCTAssertEqual(pixel(1, 0), [255, 0, 0])
        XCTAssertEqual(pixel(0, 3), [0, 0, 255])
    }

    private func fixture() throws -> Data {
        let pixels = Data(repeating: 255, count: 16 * 16 * 4)
        let provider = try XCTUnwrap(CGDataProvider(data: pixels as CFData))
        let image = try XCTUnwrap(CGImage(width: 16, height: 16, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: 64, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        let data = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image,
            [kCGImagePropertyPNGDictionary: [kCGImagePropertyPNGDescription: "synthetic-private-metadata"]] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return data as Data
    }
}
