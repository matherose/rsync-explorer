import Foundation

struct LyricLine: Equatable {
    let time: TimeInterval?   // nil = unsynced
    let text: String
}

/// Parses LRC lyrics. Lines with one or more `[mm:ss.xx]` tags become timed entries
/// (sorted); plain lines become untimed entries. `[offset:ms]` and `[id:..]` tags handled.
enum LRCParser {
    private static let tsPattern = try! NSRegularExpression(
        pattern: #"\[(\d{1,3}):(\d{1,2})(?:[.:](\d{1,3}))?\]"#)

    static func parse(_ text: String) -> [LyricLine] {
        var offset: TimeInterval = 0
        var timed: [LyricLine] = []
        var plain: [LyricLine] = []

        for raw in text.split(omittingEmptySubsequences: false, whereSeparator: { $0 == "\n" || $0 == "\r" }) {
            let line = String(raw)
            if line.trimmingCharacters(in: .whitespaces).isEmpty { continue }

            if let r = line.range(of: #"(?i)\[offset:\s*([+-]?\d+)\s*\]"#, options: .regularExpression) {
                let digits = line[r].filter { $0.isNumber || $0 == "-" || $0 == "+" }
                if let ms = Int(digits) { offset = Double(ms) / 1000 }
                continue
            }

            let ns = line as NSString
            let matches = tsPattern.matches(in: line, range: NSRange(location: 0, length: ns.length))
            if matches.isEmpty {
                // Skip ID tags like [ar:..], [ti:..].
                if line.range(of: #"^\s*\[[a-zA-Z]+:.*\]\s*$"#, options: .regularExpression) != nil { continue }
                let t = line.trimmingCharacters(in: .whitespaces)
                if !t.isEmpty { plain.append(LyricLine(time: nil, text: t)) }
                continue
            }

            var content = line
            for m in matches.reversed() {
                content = (content as NSString).replacingCharacters(in: m.range, with: "")
            }
            content = content.trimmingCharacters(in: .whitespaces)
            for m in matches {
                let mm = Double(ns.substring(with: m.range(at: 1))) ?? 0
                let ss = Double(ns.substring(with: m.range(at: 2))) ?? 0
                var frac = 0.0
                if m.range(at: 3).location != NSNotFound {
                    frac = Double("0." + ns.substring(with: m.range(at: 3))) ?? 0
                }
                timed.append(LyricLine(time: max(0, mm * 60 + ss + frac - offset), text: content))
            }
        }
        if !timed.isEmpty { return timed.sorted { ($0.time ?? 0) < ($1.time ?? 0) } }
        return plain
    }
}
