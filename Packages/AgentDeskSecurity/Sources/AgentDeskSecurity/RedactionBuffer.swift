import Foundation

/// Buffers one bounded logical message. No raw/partial prefix is returned across chunk boundaries.
/// Live progress can continue through metadata events while this record is incomplete.
public actor RedactionBuffer: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public enum Format: Sendable { case text, json }
    private let redactor: ContentRedactor
    private let classification: EvidenceClassification
    private let format: Format
    private var bytes = Data()
    private var finished = false
    public nonisolated var description: String { "<private redaction buffer>" }
    public nonisolated var debugDescription: String { description }
    public nonisolated var customMirror: Mirror { Mirror(self, children: ["content": description]) }
    public init(redactor: ContentRedactor, format: Format = .text, classification: EvidenceClassification = .internalData) {
        self.redactor = redactor; self.format = format; self.classification = classification
    }
    public func append(_ chunk: Data) throws {
        do {
            try Task.checkCancellation()
            guard !finished else { throw RedactionError.streamFinished }
            guard chunk.count <= 262_144 - bytes.count else { throw RedactionError.sizeLimit }
            bytes.append(chunk)
        } catch { cancel(); throw error }
    }
    public func finish() throws -> RedactedText {
        guard !finished else { throw RedactionError.streamFinished }
        finished = true
        defer { bytes.removeAll(keepingCapacity: false) }
        try Task.checkCancellation()
        guard let text = String(data: bytes, encoding: .utf8) else { throw RedactionError.invalidContent }
        switch format {
        case .text: return try redactor.redactText(text, in: redactor.context, classification: classification)
        case .json: return try redactor.redactJSON(text, in: redactor.context, classification: classification)
        }
    }
    public func cancel() { finished = true; bytes.removeAll(keepingCapacity: false) }
}
