import AgentDeskCore
import AgentDeskSecurity
import CoreGraphics
import Foundation
import ImageIO
import XCTest
@testable import AgentDeskPlugins

final class JiraImageAttachmentDraftTests: XCTestCase {
    func testMultipartUsesProcessedPNGAndBindsExactReview() throws {
        let context = RedactionContext(scope: .init(workspaceID: WorkspaceID(), projectID: ProjectID()), environmentID: EnvironmentID(), runID: RunID())
        let redactor = try ContentRedactor(context: context)
        let image = try ImageEvidenceRedactor.mask(fixture(), regions: [.init(x: 0, y: 0, width: 1, height: 1)], in: context)
        let filename = try redactor.redactText("evidence.png", in: context)
        let draft = try JiraImageAttachmentDraft(identifier: "SYN-1", filename: filename, image: image)
        let png = try image.withPNG(in: context) { $0 }
        XCTAssertEqual(draft.byteCount, png.count)
        XCTAssertNotNil(draft.body.range(of: png))
        XCTAssertTrue(String(decoding: draft.body.prefix(220), as: UTF8.self).contains("Content-Type: image/png"))
        XCTAssertEqual(draft.maskCount, 1)
        XCTAssertEqual(draft.width, 2); XCTAssertEqual(draft.height, 2)
        XCTAssertEqual(draft.boundary.count, 70)
        XCTAssertFalse(String(reflecting: draft).contains("evidence.png"))
        for name in ["../evidence.png", "evidence.jpg", "x\r\n.png", ".png"] {
            XCTAssertThrowsError(try JiraImageAttachmentDraft(identifier: "SYN-1", filename: redactor.redactText(name, in: context), image: image))
        }
        let config = try JiraConnectionConfiguration(scope: context.scope, environmentID: context.environmentID,
            instance: URL(string: "https://synthetic.atlassian.net")!, enabled: true)
        let permissions = try PluginPermissions(connectionID: config.id, scope: context.scope, environmentID: context.environmentID, rules: [.init(.attachmentsAdd, .approval)])
        let id = UUID(), cloud = UUID()
        func prepare(_ value: JiraImageAttachmentDraft, cloudID: UUID) throws -> PreparedPluginAction {
            try value.prepare(id: id, configuration: config, configurationRevision: 1, permissions: permissions, cloudID: cloudID, runID: context.runID)
        }
        let action = try prepare(draft, cloudID: cloud)
        XCTAssertEqual(action.capability, .attachmentsAdd)
        XCTAssertEqual(action.action, try prepare(draft, cloudID: cloud).action)
        XCTAssertNotEqual(action.action, try prepare(draft, cloudID: UUID()).action)
        let changedImage = try ImageEvidenceRedactor.mask(fixture(), regions: [], in: context)
        XCTAssertNotEqual(action.action, try prepare(JiraImageAttachmentDraft(identifier: "SYN-1", filename: filename, image: changedImage), cloudID: cloud).action)
        let foreign = RedactionContext(scope: context.scope, environmentID: context.environmentID, runID: RunID())
        let foreignName = try ContentRedactor(context: foreign).redactText("evidence.png", in: foreign)
        XCTAssertThrowsError(try JiraImageAttachmentDraft(identifier: "SYN-1", filename: foreignName, image: image))
    }

    private func fixture() throws -> Data {
        let provider = try XCTUnwrap(CGDataProvider(data: Data(repeating: 255, count: 16) as CFData))
        let image = try XCTUnwrap(CGImage(width: 2, height: 2, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: 8,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: .init(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        let data = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return data as Data
    }
}
