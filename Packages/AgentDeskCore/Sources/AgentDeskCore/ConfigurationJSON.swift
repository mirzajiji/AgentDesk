import Foundation

/// Bounded configuration decoding shared with native machine-local stores. Duplicate keys fail closed.
public enum ConfigurationJSON {
    public static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        _ = try OutputJSON.parse(data)
        return try JSONDecoder().decode(type, from: data)
    }
}
