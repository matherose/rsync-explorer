import Foundation

enum INIParser {
    /// Returns [sectionName: [key: value]]. Comments start with # or ;.
    static func parse(_ text: String) -> [String: [String: String]] {
        var result: [String: [String: String]] = [:]
        var current: String?
        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") || line.hasPrefix(";") { continue }
            if line.hasPrefix("[") && line.hasSuffix("]") {
                let name = String(line.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)
                current = name
                result[name] = result[name] ?? [:]
            } else if let eq = line.firstIndex(of: "="), let section = current {
                let key = line[..<eq].trimmingCharacters(in: .whitespaces)
                let value = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
                result[section]?[key] = value
            }
        }
        return result
    }
}
