import Foundation

/// Low-level helpers for walking LaTeX source as an array of Characters.
/// Everything here is deliberately forgiving: unbalanced input never crashes,
/// it just consumes to the end.
struct LatexScanner {
    let s: [Character]
    var i: Int = 0

    init(_ text: String) { s = Array(text) }
    init(_ chars: [Character]) { s = chars }

    var atEnd: Bool { i >= s.count }
    var peek: Character? { i < s.count ? s[i] : nil }
    func peek(_ offset: Int) -> Character? { i + offset < s.count ? s[i + offset] : nil }

    mutating func skipSpaces() {
        while i < s.count, s[i].isWhitespace { i += 1 }
    }

    /// Skips spaces but stops at a blank line (paragraph break) — mostly irrelevant for tables.
    mutating func skipInlineSpaces() {
        while i < s.count, s[i] == " " || s[i] == "\t" || s[i] == "\n" || s[i] == "\r" { i += 1 }
    }

    func hasPrefix(_ p: String, at pos: Int? = nil) -> Bool {
        var k = pos ?? i
        for c in p {
            guard k < s.count, s[k] == c else { return false }
            k += 1
        }
        return true
    }

    /// Reads a control sequence name at the current position (which must be a backslash).
    /// Returns the name without the backslash ("textbf", "%", "\\").
    mutating func readCommand() -> String? {
        guard peek == "\\" else { return nil }
        i += 1
        guard i < s.count else { return "" }
        if s[i].isLetter || s[i] == "@" {
            let start = i
            while i < s.count, s[i].isLetter || s[i] == "@" { i += 1 }
            return String(s[start..<i])
        }
        let c = s[i]
        i += 1
        return String(c)
    }

    /// Reads a balanced {...} group, returning its inner text. If the next token isn't a
    /// brace, reads a single token (TeX semantics for undelimited args).
    mutating func readArg() -> String? {
        skipSpaces()
        guard let c = peek else { return nil }
        if c == "{" { return readBraced() }
        if c == "\\" {
            let start = i
            _ = readCommand()
            return String(s[start..<i])
        }
        i += 1
        return String(c)
    }

    /// Reads {...} if present at the current position (after spaces). Returns nil otherwise.
    mutating func readBraced() -> String? {
        let save = i
        skipSpaces()
        guard peek == "{" else { i = save; return nil }
        i += 1
        let start = i
        var depth = 1
        while i < s.count {
            let c = s[i]
            if c == "\\" { i += 2; continue }
            if c == "{" { depth += 1 } else if c == "}" {
                depth -= 1
                if depth == 0 {
                    let inner = String(s[start..<i])
                    i += 1
                    return inner
                }
            }
            i += 1
        }
        return String(s[start..<min(i, s.count)])
    }

    /// Reads an optional [...] argument if present.
    mutating func readOptional() -> String? {
        let save = i
        skipSpaces()
        guard peek == "[" else { i = save; return nil }
        i += 1
        let start = i
        var depth = 0
        while i < s.count {
            let c = s[i]
            if c == "\\" { i += 2; continue }
            if c == "{" { depth += 1 } else if c == "}" { depth -= 1 } else if c == "]" && depth <= 0 {
                let inner = String(s[start..<i])
                i += 1
                return inner
            }
            i += 1
        }
        return String(s[start..<min(i, s.count)])
    }

    /// Reads an optional (...) argument (booktabs \cmidrule(lr)).
    mutating func readParen() -> String? {
        let save = i
        skipSpaces()
        guard peek == "(" else { i = save; return nil }
        i += 1
        let start = i
        while i < s.count, s[i] != ")" { i += 1 }
        let inner = String(s[start..<min(i, s.count)])
        if i < s.count { i += 1 }
        return inner
    }

    mutating func skipStar() {
        if peek == "*" { i += 1 }
    }
}

enum Latex {
    /// Removes `%` comments (respecting `\%`). Keeps line structure.
    static func stripComments(_ text: String) -> String {
        guard text.contains("%") else { return text }
        var out = ""
        out.reserveCapacity(text.count)
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            var prevBackslashes = 0
            var cut: String.Index? = nil
            var idx = line.startIndex
            while idx < line.endIndex {
                let c = line[idx]
                if c == "%" && prevBackslashes % 2 == 0 { cut = idx; break }
                prevBackslashes = (c == "\\") ? prevBackslashes + 1 : 0
                idx = line.index(after: idx)
            }
            if let cut {
                out += line[line.startIndex..<cut]
                // A comment at end of line also eats the newline (TeX semantics).
            } else {
                out += line
                out += "\n"
            }
        }
        return out
    }

    /// Finds the matching `\end{name}` for a `\begin{name}` whose body starts at `from`.
    /// Returns (bodyEnd, afterEnd) indices.
    static func findEnd(of name: String, in s: [Character], from: Int) -> (Int, Int)? {
        let beginTok = Array("\\begin{\(name)}")
        let endTok = Array("\\end{\(name)}")
        var depth = 1
        var k = from
        while k < s.count {
            if s[k] == "\\" {
                if matches(s, k, beginTok) { depth += 1; k += beginTok.count; continue }
                if matches(s, k, endTok) {
                    depth -= 1
                    if depth == 0 { return (k, k + endTok.count) }
                    k += endTok.count
                    continue
                }
                k += 2
                continue
            }
            k += 1
        }
        return nil
    }

    static func matches(_ s: [Character], _ at: Int, _ tok: [Character]) -> Bool {
        guard at + tok.count <= s.count else { return false }
        for j in 0..<tok.count where s[at + j] != tok[j] { return false }
        return true
    }

    static func htmlEscape(_ s: String) -> String {
        var out = ""
        out.reserveCapacity(s.count)
        for c in s {
            switch c {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            default: out.append(c)
            }
        }
        return out
    }
}
