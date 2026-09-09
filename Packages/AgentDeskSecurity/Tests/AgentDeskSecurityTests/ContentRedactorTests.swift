import AgentDeskCore
import Foundation
import XCTest
@testable import AgentDeskSecurity

@MainActor
final class ContentRedactorTests: XCTestCase {
    private var context: RedactionContext {
        RedactionContext(scope: ProjectScope(workspaceID: WorkspaceID(), projectID: ProjectID()), environmentID: EnvironmentID(), runID: RunID())
    }
    private func redactor(_ values: [String], context: RedactionContext, fields: [String] = []) async throws -> ContentRedactor {
        let scope = try SecretScope(workspaceID: context.scope.workspaceID, projectID: context.scope.projectID, environmentID: context.environmentID)
        let references = values.map { _ in SecretReference(scope: scope) }
        let secrets = try Dictionary(uniqueKeysWithValues: zip(references, values.map { try SecretValue(Data($0.utf8)) }))
        return try await ContentRedactor.load(context: context, sensitiveFields: fields, references: references) { secrets[$0] }
    }
    func testKnownOverlappingAndEncodedValuesAreRemovedWithoutChangingPublicText() async throws {
        let context = context, secret = "synthetic/P@ss-🔒"
        let redactor = try await redactor([secret, "overlap", "overlapping-value"], context: context)
        let encoded = String(decoding: try JSONEncoder().encode(secret), as: UTF8.self)
        let forms = [secret, String(encoded.dropFirst().dropLast()), Data(secret.utf8).base64EncodedString(),
                     secret.utf8.map { String(format: "%02x", $0) }.joined(),
                     secret.utf8.map { String(format: "%%%02X", $0) }.joined(),
                     secret.utf16.map { String(format: "\\u%04x", $0) }.joined(),
                     secret.addingPercentEncoding(withAllowedCharacters: .alphanumerics)!]
        for value in forms {
            let result = try redactor.redactText("Public prefix \(value) public suffix", in: context)
            XCTAssertEqual(result.text, "Public prefix [REDACTED] public suffix")
            XCTAssertEqual(result.classification, .confidential); XCTAssertEqual(result.redactionCount, 1)
        }
        let overlap = try redactor.redactText("overlapping-value and overlap", in: context)
        XCTAssertEqual(overlap.text, "[REDACTED] and [REDACTED]"); XCTAssertEqual(overlap.redactionCount, 2)
    }
    func testCredentialHeadersCookiesURLsPEMAndTokenPatternsAreMasked() throws {
        let context = context, redactor = try ContentRedactor(context: context)
        let token = "ghp_" + String(repeating: "S", count: 36)
        let text = """
            status=200
            password=synthetic-pass
            Authorization: Bearer synthetic-access
            Cookie: session=synthetic-session; another=synthetic-cookie
            url=postgresql://synthetic:synthetic-db@localhost/db
            \(token)
            -----BEGIN PRIVATE KEY-----
            synthetic-private-material
            -----END PRIVATE KEY-----
            public result
            """
        let result = try redactor.redactText(text, in: context)
        for secret in ["synthetic-pass", "synthetic-access", "synthetic-session", "synthetic-cookie", "synthetic-db", token, "synthetic-private-material"] {
            XCTAssertFalse(result.text.contains(secret), secret)
        }
        XCTAssertTrue(result.text.contains("status=200")); XCTAssertTrue(result.text.contains("public result"))
        let truncated = try redactor.redactText("before\n-----BEGIN RSA PRIVATE KEY-----\nunclosed synthetic key", in: context)
        XCTAssertEqual(truncated.text, "before\n[REDACTED]")
    }
    func testMixedPercentEncodingFormSpacesAndOverlappingMatchesPreservePublicUnicode() async throws {
        let context = context, redactor = try await redactor(["sYnthetic-🔒", "synthetic space", "ababa"], context: context)
        for encoded in ["%73Ynthetic%2d%f0%9F%94%92", "sYnthetic-%F0%9f%94%92", "synthetic+space", "synthetic%20space"] {
            XCTAssertEqual(try redactor.redactText("🧪 \(encoded) é %invalid", in: context).text, "🧪 [REDACTED] é %invalid")
        }
        XCTAssertEqual(try redactor.redactText("abababa", in: context).text, "[REDACTED]")
        XCTAssertEqual(try redactor.redactJSON(#"{"note":"%73Ynthetic%2d%f0%9F%94%92"}"#, in: context).text, #"{"note":"[REDACTED]"}"#)
        let reference = SecretReference(scope: try SecretScope(workspaceID: context.scope.workspaceID))
        let binary = try await ContentRedactor.load(context: context, references: [reference]) { _ in try SecretValue(Data([0x94])) }
        XCTAssertEqual(try binary.redactText("before 🔒 after %invalid", in: context).text, "before [REDACTED] after %invalid")
    }
    func testStructuredFieldsMaskWholeSubtreesAndPreserveUnrelatedNumericBytes() async throws {
        let context = context, redactor = try await redactor(["synthetic-known", "123456"], context: context, fields: ["privatePayload"])
        let input = #"{ "amount": 123456789012345678901234567890.1234500, "small":1e-900, "password":true, "private_payload":{"notUsuallySensitive":[1,"private"],"nested":{"x":2}}, "note":"prefix synthetic-known suffix", "pin":123456, "safe":[false,null,"tokenCount=3"] }"#
        let output = try redactor.redactJSON(input, in: context)
        // Known numeric secrets are deliberately masked even inside an otherwise non-sensitive field.
        XCTAssertFalse(output.text.contains("123456789012345678901234567890.1234500"))
        XCTAssertTrue(output.text.contains(#""small":1e-900"#))
        XCTAssertTrue(output.text.contains(#""password":"[REDACTED]""#))
        XCTAssertTrue(output.text.contains(#""private_payload":"[REDACTED]""#))
        XCTAssertTrue(output.text.contains(#""note":"[REDACTED]""#)); XCTAssertTrue(output.text.contains(#""pin":"[REDACTED]""#))
        XCTAssertTrue(output.text.contains(#""safe":[false,null,"tokenCount=3"]"#))
        let numeric = #" {"amount":987654321098765432109876543210.1234500,"exponent":1e+999,"negative":-0.0} "#
        XCTAssertEqual(try ContentRedactor(context: context).redactJSON(numeric, in: context).text, numeric)
    }
    func testEscapedJSONFieldNamesAndMixedUnicodeEscapeSecretsAreRecognized() async throws {
        let context = context, redactor = try await redactor(["Jij-X"], context: context)
        let text = #"{"\u0070assword":"private","note":"\u004A\u0069\u006A-\u0058","API_KEY":"private-two","notPassword":"public"}"#
        let result = try redactor.redactJSON(text, in: context)
        XCTAssertFalse(result.text.contains("private")); XCTAssertFalse(result.text.contains(#"\u004A"#))
        XCTAssertTrue(result.text.contains(#""notPassword":"public""#)); XCTAssertEqual(result.redactionCount, 3)
    }
    func testPublicTextAndClassificationArePreservedAndSecretRecordsAreRefused() throws {
        let context = context, redactor = try ContentRedactor(context: context)
        let text = "Public tokenizer results. tokenCount=3; authorizationEnabled=false. notPassword=public. Basic arithmetic. 🧪"
        let result = try redactor.redactText(text, in: context, classification: .publicData)
        XCTAssertEqual(result.text, text); XCTAssertEqual(result.redactionCount, 0); XCTAssertEqual(result.classification, .publicData)
        XCTAssertEqual(try redactor.redactText("already confidential", in: context, classification: .confidential).classification, .confidential)
        XCTAssertThrowsError(try redactor.redactText("whole secret record", in: context, classification: .secret)) { XCTAssertEqual($0 as? RedactionError, .secretClassification) }
    }
    func testCrossContextAndForeignReferencesFailBeforeResolvingSecrets() async throws {
        actor Counter { var count = 0; func bump() { count += 1 } }
        let context = context, counter = Counter(), redactor = try ContentRedactor(context: context)
        let foreign = SecretReference(scope: try SecretScope(workspaceID: WorkspaceID()))
        do {
            _ = try await ContentRedactor.load(context: context, references: [foreign]) { _ in await counter.bump(); return nil }
            XCTFail()
        } catch { XCTAssertEqual(error as? RedactionError, .scopeMismatch) }
        let count = await counter.count; XCTAssertEqual(count, 0)
        for requested in [self.context, RedactionContext(scope: context.scope, environmentID: EnvironmentID(), runID: context.runID),
                          RedactionContext(scope: context.scope, environmentID: context.environmentID, runID: RunID())] {
            XCTAssertThrowsError(try redactor.redactText("text", in: requested)) { XCTAssertEqual($0 as? RedactionError, .scopeMismatch) }
            XCTAssertThrowsError(try redactor.redactJSON("{}", in: requested)) { XCTAssertEqual($0 as? RedactionError, .scopeMismatch) }
        }
    }
    func testScopedInheritedSecretsMissingFailuresAndPolicyBounds() async throws {
        let context = context
        let workspace = SecretReference(scope: try SecretScope(workspaceID: context.scope.workspaceID))
        let project = SecretReference(scope: try SecretScope(workspaceID: context.scope.workspaceID, projectID: context.scope.projectID))
        let secret = try SecretValue(Data("synthetic-shared-value".utf8))
        let redactor = try await ContentRedactor.load(context: context, references: [workspace, project]) { _ in secret }
        XCTAssertEqual(try redactor.redactText("synthetic-shared-value", in: context).text, "[REDACTED]")
        do { _ = try await ContentRedactor.load(context: context, references: [project]) { _ in nil }; XCTFail() }
        catch { XCTAssertEqual(error as? RedactionError, .secretUnavailable) }
        do { _ = try await ContentRedactor.load(context: context, references: [project]) { _ in throw SecretStoreError.keychain(-1) }; XCTFail() }
        catch { XCTAssertEqual(error as? RedactionError, .secretUnavailable) }
        do { _ = try await ContentRedactor.load(context: context, references: [project, project]) { _ in secret }; XCTFail() }
        catch { XCTAssertEqual(error as? RedactionError, .invalidPolicy) }
        for fields in [["---"], ["[invalid regex]"], Array(repeating: "privateField", count: 65)] { XCTAssertThrowsError(try ContentRedactor(context: context, sensitiveFields: fields)) }
    }
    func testDescriptionsAndSerializationNeverContainConfiguredSecretValues() async throws {
        let context = context, secret = "synthetic-never-in-diagnostics"
        let redactor = try await redactor([secret], context: context)
        var dumpText = ""; dump(redactor, to: &dumpText)
        XCTAssertFalse(dumpText.contains(secret)); XCTAssertFalse(String(reflecting: redactor).contains(secret))
        let safe = try redactor.redactText(secret, in: context)
        let json = String(decoding: try JSONEncoder().encode(safe), as: UTF8.self)
        XCTAssertFalse(json.contains(secret)); XCTAssertTrue(json.contains("[REDACTED]")); XCTAssertEqual(safe.context, context)
    }
    func testMalformedDeepDuplicateAndPrivateKeyJSONNamesFailWithoutPartialOutput() async throws {
        let context = context, redactor = try await redactor(["synthetic-private-key"], context: context)
        for text in ["", "{}{}", #"{"x":1,"x":2}"#, #"{"x":1,"\u0078":2}"#, #"{"x":01}"#, #"{"x":NaN}"#,
                     #"{"x":1e}"#, #"{"x":+1}"#, #"{"x":null,}"#, #"{"x":"\uD800"}"#, #"{"synthetic-private-key":1}"#,
                     String(repeating: "[", count: 42) + "1" + String(repeating: "]", count: 42)] {
            XCTAssertThrowsError(try redactor.redactJSON(text, in: context), text)
        }
        let tooMany = "[" + Array(repeating: "null", count: 8_193).joined(separator: ",") + "]"
        XCTAssertThrowsError(try redactor.redactJSON(tooMany, in: context))
        XCTAssertThrowsError(try redactor.redactText(String(repeating: "x", count: 262_145), in: context))
    }
    func testEveryByteBoundaryKeepsUTF8AndSplitSecretsPrivateUntilFinish() async throws {
        let context = context, redactor = try await redactor(["synthetic-token-🧪"], context: context)
        let data = Data("Before synthetic-token-🧪 after".utf8)
        for boundary in 0...data.count {
            let stream = RedactionBuffer(redactor: redactor)
            try await stream.append(data.prefix(boundary)); try await stream.append(data.suffix(data.count - boundary))
            let result = try await stream.finish(); XCTAssertEqual(result.text, "Before [REDACTED] after")
            do { _ = try await stream.finish(); XCTFail() } catch { XCTAssertEqual(error as? RedactionError, .streamFinished) }
        }
        let json = RedactionBuffer(redactor: redactor, format: .json)
        for byte in Data(#"{"pass\u0077ord":"private"}"#.utf8) { try await json.append(Data([byte])) }
        let result = try await json.finish(); XCTAssertFalse(result.text.contains("private"))
    }
    func testStreamOverflowInvalidUTF8AndCancellationCloseAndDiscardTheRecord() async throws {
        let context = context, redactor = try ContentRedactor(context: context)
        let overflow = RedactionBuffer(redactor: redactor)
        do { try await overflow.append(Data(repeating: 65, count: 262_145)); XCTFail() } catch { XCTAssertEqual(error as? RedactionError, .sizeLimit) }
        do { _ = try await overflow.finish(); XCTFail() } catch { XCTAssertEqual(error as? RedactionError, .streamFinished) }
        let invalid = RedactionBuffer(redactor: redactor)
        try await invalid.append(Data([0xff]))
        do { _ = try await invalid.finish(); XCTFail() } catch { XCTAssertEqual(error as? RedactionError, .invalidContent) }
        let cancelled = RedactionBuffer(redactor: redactor)
        try await cancelled.append(Data("pending private text".utf8)); await cancelled.cancel()
        do { _ = try await cancelled.finish(); XCTFail() } catch { XCTAssertEqual(error as? RedactionError, .streamFinished) }
        let task = Task { () throws -> RedactedText in
            withUnsafeCurrentTask { $0?.cancel() }
            return try redactor.redactText("unpublished", in: context)
        }
        do { _ = try await task.value; XCTFail() } catch { XCTAssertTrue(error is CancellationError) }
    }
}
