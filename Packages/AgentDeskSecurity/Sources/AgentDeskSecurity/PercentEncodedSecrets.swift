import Foundation

/// Finds known bytes through one layer of URL/form encoding, retaining ranges in the original text.
/// Mixed hex case and optional encoding of unreserved characters must not evade the policy.
enum PercentEncodedSecrets {
    static func ranges(in text: String, secrets: [Data]) throws -> [NSRange] {
        guard !secrets.isEmpty, text.utf8.contains(37) || text.utf8.contains(43) else { return [] }
        let original = Array(text.utf8)
        // Each UTF-8 byte maps to its entire source scalar. A binary secret matching inside a scalar
        // conservatively masks that scalar instead of producing malformed UTF-16 replacements.
        var scalarRanges: [NSRange] = [], offset = 0
        scalarRanges.reserveCapacity(original.count)
        for scalar in text.unicodeScalars {
            let range = NSRange(location: offset, length: scalar.utf16.count)
            scalarRanges.append(contentsOf: repeatElement(range, count: scalar.utf8.count))
            offset += range.length
        }
        var found: [NSRange] = []
        for formEncoding in [false, true] {
            if formEncoding && !original.contains(43) { continue }
            try Task.checkCancellation()
            var decoded = Data(), sourceRanges: [NSRange] = [], index = 0
            decoded.reserveCapacity(original.count); sourceRanges.reserveCapacity(original.count)
            while index < original.count {
                let start = index, byte: UInt8
                if original[index] == 37, index + 2 < original.count,
                   let high = hex(original[index + 1]), let low = hex(original[index + 2]) {
                    byte = high * 16 + low; index += 3
                } else {
                    byte = formEncoding && original[index] == 43 ? 32 : original[index]; index += 1
                }
                decoded.append(byte)
                sourceRanges.append(NSUnionRange(scalarRanges[start], scalarRanges[index - 1]))
            }
            for secret in secrets {
                try Task.checkCancellation()
                var next = 0
                while next < decoded.count, let match = decoded.range(of: secret, in: next..<decoded.count) {
                    found.append(NSUnionRange(sourceRanges[match.lowerBound], sourceRanges[match.upperBound - 1]))
                    guard found.count <= 65_536 else { throw RedactionError.sizeLimit }
                    next = match.lowerBound + 1
                }
            }
        }
        return found
    }
    private static func hex(_ byte: UInt8) -> UInt8? {
        switch byte {
        case 48...57: return byte - 48
        case 65...70: return byte - 55
        case 97...102: return byte - 87
        default: return nil
        }
    }
}
