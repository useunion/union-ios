import Foundation

/// Minimal JSON Schema (draft-07 subset, as emitted by zod-to-json-schema) validator used only in tests to prove
/// every batch the SDK encodes conforms to packages/contract/schema/event-batch.v1.json.
struct MiniSchemaValidator {
    let root: [String: Any]

    init(schema: Data) throws {
        root = try JSONSerialization.jsonObject(with: schema) as? [String: Any] ?? [:]
    }

    func validate(_ json: Data) throws -> [String] {
        let value = try JSONSerialization.jsonObject(with: json, options: [.fragmentsAllowed])
        var errors: [String] = []
        check(value, schema: root, path: "$", errors: &errors)
        return errors
    }

    private func resolve(_ schema: [String: Any]) -> [String: Any] {
        guard let ref = schema["$ref"] as? String, ref.hasPrefix("#/") else { return schema }
        var node: Any = root
        for part in ref.dropFirst(2).split(separator: "/") {
            guard let dict = node as? [String: Any], let next = dict[String(part)] else { return schema }
            node = next
        }
        return node as? [String: Any] ?? schema
    }

    private func check(_ value: Any, schema raw: [String: Any], path: String, errors: inout [String]) {
        let schema = resolve(raw)
        if let anyOf = schema["anyOf"] as? [[String: Any]] {
            let ok = anyOf.contains { branch in
                var e: [String] = []
                check(value, schema: branch, path: path, errors: &e)
                return e.isEmpty
            }
            if !ok { errors.append("\(path): matches no anyOf branch") }
            return
        }
        if let const = schema["const"] { if !equal(value, const) { errors.append("\(path): expected const \(const)") } }
        if let en = schema["enum"] as? [Any] { if !en.contains(where: { equal(value, $0) }) { errors.append("\(path): not in enum") } }
        if let type = schema["type"] as? String { if !matches(type: type, value) { errors.append("\(path): expected \(type)") } }

        if let s = value as? String {
            if let min = schema["minLength"] as? Int, s.count < min { errors.append("\(path): shorter than \(min)") }
            if let max = schema["maxLength"] as? Int, s.count > max { errors.append("\(path): longer than \(max)") }
            if let p = schema["pattern"] as? String, s.range(of: p, options: .regularExpression) == nil { errors.append("\(path): pattern \(p)") }
            if schema["format"] as? String == "uuid", UUID(uuidString: s) == nil { errors.append("\(path): not a uuid") }
        }
        if let n = value as? NSNumber, !(value is Bool) {
            if let min = schema["minimum"] as? Double, n.doubleValue < min { errors.append("\(path): below minimum") }
        }
        if let arr = value as? [Any] {
            if let min = schema["minItems"] as? Int, arr.count < min { errors.append("\(path): fewer than \(min) items") }
            if let max = schema["maxItems"] as? Int, arr.count > max { errors.append("\(path): more than \(max) items") }
            if let items = schema["items"] as? [String: Any] { for (i, v) in arr.enumerated() { check(v, schema: items, path: "\(path)[\(i)]", errors: &errors) } }
        }
        if let obj = value as? [String: Any] {
            let props = schema["properties"] as? [String: [String: Any]] ?? [:]
            for req in schema["required"] as? [String] ?? [] where obj[req] == nil { errors.append("\(path): missing \(req)") }
            for (k, v) in obj {
                if let sub = props[k] { check(v, schema: sub, path: "\(path).\(k)", errors: &errors) }
                else if let add = schema["additionalProperties"] {
                    if let addBool = add as? Bool, addBool == false { errors.append("\(path): unexpected property \(k)") }
                    else if let addSchema = add as? [String: Any] { check(v, schema: addSchema, path: "\(path).\(k)", errors: &errors) }
                }
            }
            if let pn = schema["propertyNames"] as? [String: Any] { for k in obj.keys { check(k, schema: pn, path: "\(path).<key:\(k)>", errors: &errors) } }
            if let maxP = schema["maxProperties"] as? Int, obj.count > maxP { errors.append("\(path): more than \(maxP) properties") }
        }
    }

    private func matches(type: String, _ v: Any) -> Bool {
        switch type {
        case "string": return v is String
        case "boolean": return v is Bool && (v as? NSNumber).map { CFGetTypeID($0) == CFBooleanGetTypeID() } ?? true
        case "number": return v is NSNumber && !isBool(v)
        case "integer": return (v as? NSNumber).map { !isBool(v) && $0.doubleValue == $0.doubleValue.rounded() } ?? false
        case "object": return v is [String: Any]
        case "array": return v is [Any]
        case "null": return v is NSNull
        default: return true
        }
    }

    private func isBool(_ v: Any) -> Bool { (v as? NSNumber).map { CFGetTypeID($0) == CFBooleanGetTypeID() } ?? false }

    private func equal(_ a: Any, _ b: Any) -> Bool {
        if let x = a as? String, let y = b as? String { return x == y }
        if let x = a as? NSNumber, let y = b as? NSNumber { return x == y }
        return false
    }
}
