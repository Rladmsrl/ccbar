import Foundation

enum UsageLimitDateParser {
    private static let withFraction = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
    private static let withoutFraction = Date.ISO8601FormatStyle(includingFractionalSeconds: false)

    static func date(from string: String) -> Date? {
        if let seconds = TimeInterval(string) {
            return Date(timeIntervalSince1970: seconds)
        }
        if let date = try? withFraction.parse(string) {
            return date
        }
        return try? withoutFraction.parse(string)
    }
}

enum UsageLimitDecoding {
    static func decodeDouble<Key: CodingKey>(_ container: KeyedDecodingContainer<Key>, forKey key: Key) -> Double? {
        if let value = try? container.decode(Double.self, forKey: key) {
            return value
        }
        if let value = try? container.decode(Int.self, forKey: key) {
            return Double(value)
        }
        if let value = try? container.decode(String.self, forKey: key) {
            return Double(value)
        }
        return nil
    }

    static func decodeInt<Key: CodingKey>(_ container: KeyedDecodingContainer<Key>, forKey key: Key) -> Int? {
        if let value = try? container.decode(Int.self, forKey: key) {
            return value
        }
        if let value = try? container.decode(Double.self, forKey: key) {
            return Int(value)
        }
        if let value = try? container.decode(String.self, forKey: key) {
            if let int = Int(value) {
                return int
            }
            if let double = Double(value) {
                return Int(double)
            }
        }
        return nil
    }

    static func decodeDate<Key: CodingKey>(_ container: KeyedDecodingContainer<Key>, forKey key: Key) -> Date? {
        if let value = try? container.decode(Double.self, forKey: key) {
            return Date(timeIntervalSince1970: value)
        }
        if let value = try? container.decode(Int.self, forKey: key) {
            return Date(timeIntervalSince1970: TimeInterval(value))
        }
        if let value = try? container.decode(String.self, forKey: key) {
            return UsageLimitDateParser.date(from: value)
        }
        return nil
    }

    static func number(from value: Any?) -> Double? {
        switch value {
        case let number as NSNumber:
            number.doubleValue
        case let string as String:
            Double(string)
        default:
            nil
        }
    }

    static func date(from value: Any?) -> Date? {
        switch value {
        case let number as NSNumber:
            Date(timeIntervalSince1970: number.doubleValue)
        case let string as String:
            UsageLimitDateParser.date(from: string)
        default:
            nil
        }
    }
}
