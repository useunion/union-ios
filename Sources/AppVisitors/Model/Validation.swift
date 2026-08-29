import Foundation

/// Mirror of `packages/contract/src/limits.ts`. A unit test cross-checks these against the JSON Schema fixture.
enum Limits {
    static let batchMaxEvents = 100
    static let batchMaxBytes = 256 * 1024
    static let eventNameMaxLength = 64
    static let eventNamePattern = "^[a-z][a-z0-9_]*$"
    static let maxProperties = 32
    static let propertyKeyMaxLength = 64
    static let propertyStringMaxLength = 256
    static let screenNameMaxLength = 128
    static let userIdMaxLength = 128
}

enum ValidationError: Error, CustomStringConvertible, Equatable {
    case reservedName(String)
    case invalidName(String)
    case tooManyProperties(Int)
    case invalidPropertyKey(String)
    case propertyTooLong(String)
    case nonFiniteNumber(String)
    case screenTooLong
    case userIdTooLong

    var description: String {
        switch self {
        case .reservedName(let n): return "\"\(n)\": names starting with $ are reserved for automatic events"
        case .invalidName(let n): return "\"\(n)\": name must be lowercase snake_case starting with a letter, max \(Limits.eventNameMaxLength) chars"
        case .tooManyProperties(let n): return "\(n) properties, max \(Limits.maxProperties)"
        case .invalidPropertyKey(let k): return "property key \"\(k)\" must be 1–\(Limits.propertyKeyMaxLength) chars"
        case .propertyTooLong(let k): return "property \"\(k)\" exceeds \(Limits.propertyStringMaxLength) chars"
        case .nonFiniteNumber(let k): return "property \"\(k)\" is not a finite number"
        case .screenTooLong: return "screen name exceeds \(Limits.screenNameMaxLength) chars"
        case .userIdTooLong: return "user id exceeds \(Limits.userIdMaxLength) chars"
        }
    }
}

enum Validation {
    private static let nameRegex = try! NSRegularExpression(pattern: Limits.eventNamePattern)

    static func validateCustomName(_ name: String) throws {
        if name.hasPrefix("$") { throw ValidationError.reservedName(name) }
        guard name.count <= Limits.eventNameMaxLength,
              nameRegex.firstMatch(in: name, range: NSRange(name.startIndex..., in: name)) != nil
        else { throw ValidationError.invalidName(name) }
    }

    static func validate(properties: [String: PropertyValue]) throws {
        guard properties.count <= Limits.maxProperties else { throw ValidationError.tooManyProperties(properties.count) }
        for (key, value) in properties {
            guard !key.isEmpty, key.count <= Limits.propertyKeyMaxLength else { throw ValidationError.invalidPropertyKey(key) }
            switch value {
            case .string(let s) where s.count > Limits.propertyStringMaxLength: throw ValidationError.propertyTooLong(key)
            case .number(let n) where !n.isFinite: throw ValidationError.nonFiniteNumber(key)
            default: break
            }
        }
    }

    static func validate(screen: String?) throws {
        if let s = screen, s.count > Limits.screenNameMaxLength { throw ValidationError.screenTooLong }
    }

    static func validate(userId: String) throws {
        if userId.isEmpty || userId.count > Limits.userIdMaxLength { throw ValidationError.userIdTooLong }
    }
}
