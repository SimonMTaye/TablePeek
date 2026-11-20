import Foundation

public enum ColumnAlign: String, Sendable {
    case left, center, right, justify
}

public struct ColumnSpec: Sendable {
    public var align: ColumnAlign
    public var width: String?
    /// Number of `|` rules immediately to the left / right of this column.
    public var leftRules = 0
    public var rightRules = 0
}

public enum RuleKind: Sendable {
    case thick, thin, hline, dashed
}

public struct Rule: Sendable {
    public var kind: RuleKind
    /// 1-based inclusive column range; nil = full width.
    public var from: Int?
    public var to: Int?
    public var trimLeft = false
    public var trimRight = false
    /// Partial rules (cmidrule/cline) placed side by side share a level.
    public var level = 0
}

public struct Cell: Sendable {
    public var html: String
    public var colspan = 1
    public var rowspan = 1
    public var align: ColumnAlign?
    public var spec: [ColumnSpec]? = nil  // from \multicolumn
    public var background: String?
    public var isEmpty: Bool
}

public struct Row: Sendable {
    public var cells: [Cell]
    public var rulesAbove: [Rule]
    public var extraSpaceAbove: Double = 0  // in em
    public var background: String?
}

public struct ParsedTable: Sendable {
    public var columns: [ColumnSpec]
    public var rows: [Row]
    public var trailingRules: [Rule]
    public var caption: String?
    public var notes: [String] = []
    public var envName: String
}

public struct ParseResult: Sendable {
    public var tables: [ParsedTable]
    public var elapsed: TimeInterval
}

public struct TableParser {
    static let tabularEnvs: Set<String> = [
        "tabular", "tabular*", "tabularx", "tabulary", "longtable", "longtable*", "xltabular", "NiceTabular",
        "supertabular", "tabu", "longtabu", "array",
    ]

    var macros: [String: Macro]

    public init() { macros = [:] }
    init(macros: [String: Macro]) { self.macros = macros }

    /// Entry point: parse every table in a .tex file.
    public static func parse(_ source: String) -> ParseResult {
        let t0 = Date()
        let clean = Latex.stripComments(source)
        var p = TableParser()
        p.macros = collectMacros(clean)
        let tables = p.parseTables(in: clean, depth: 0)
        return ParseResult(tables: tables, elapsed: Date().timeIntervalSince(t0))
    }

    // MARK: - Locate environments

    struct Located {
        var env: String
        var beginStart: Int
        var bodyStart: Int  // after the env's own args
        var bodyEnd: Int
        var after: Int
        var specText: String
    }

    func parseTables(in text: String, depth: Int) -> [ParsedTable] {
        let s = Array(text)
        var found: [Located] = []
        var k = 0
        let beginTok = Array("\\begin{")
        while k < s.count {
            guard s[k] == "\\" else { k += 1; continue }
            guard Latex.matches(s, k, beginTok) else { k += 2; continue }
            var sc = LatexScanner(s)
            sc.i = k + 6
            guard let env = sc.readBraced() else { k += 1; continue }
            guard Self.tabularEnvs.contains(env), depth > 0 || env != "array" else { k = sc.i; continue }
            // Env arguments
            var spec = ""
            switch env {
            case "tabular*", "tabularx", "tabulary", "xltabular", "longtable*":
                _ = sc.readOptional()
                _ = sc.readBraced()
                _ = sc.readOptional()
                spec = sc.readBraced() ?? ""
            case "tabu", "longtabu":
                // \begin{tabu} to \linewidth {spec}
                while let c = sc.peek, c != "{" { sc.i += 1 }
                spec = sc.readBraced() ?? ""
            default:
                _ = sc.readOptional()
                spec = sc.readBraced() ?? ""
            }
            let bodyStart = sc.i
            guard let (bodyEnd, after) = Latex.findEnd(of: env, in: s, from: bodyStart) else {
                k = bodyStart
                continue
            }
            found.append(Located(env: env, beginStart: k, bodyStart: bodyStart, bodyEnd: bodyEnd, after: after, specText: spec))
            k = after  // skip nested tabulars; they're rendered as cell content
        }

        var tables: [ParsedTable] = []
        for (idx, loc) in found.enumerated() {
            var t = parseTable(loc, s)
            if depth == 0 {
                let prevEnd = idx > 0 ? found[idx - 1].after : 0
                let nextStart = idx + 1 < found.count ? found[idx + 1].beginStart : s.count
                t.caption = findCaption(s, before: prevEnd..<loc.beginStart, after: loc.after..<nextStart, taken: tables.last?.caption)
                t.notes = findNotes(s, in: loc.after..<nextStart)
            }
            tables.append(t)
        }
        return tables
    }

    // MARK: - Captions & notes

    private func findCaption(_ s: [Character], before: Range<Int>, after: Range<Int>, taken: String?) -> String? {
        func captions(in r: Range<Int>) -> [String] {
            guard !r.isEmpty else { return [] }
            var out: [String] = []
            var sc = LatexScanner(Array(s[r]))
            while !sc.atEnd {
                if sc.peek == "\\" {
                    let name = sc.readCommand() ?? ""
                    if name == "caption" || name == "captionof" {
                        sc.skipStar()
                        if name == "captionof" { _ = sc.readBraced() }
                        _ = sc.readOptional()
                        if let c = sc.readBraced() { out.append(c) }
                    }
                    continue
                }
                sc.i += 1
            }
            return out
        }
        let conv = InlineConverter(macros: macros)
        if let c = captions(in: before).last {
            return conv.convert(c, ctx: CellContext())
        }
        // Caption below the table: only look until the end of the enclosing table env.
        var limit = after.upperBound
        let sub = Array(s[after])
        let endTable = Array("\\end{table")
        for j in 0..<sub.count where Latex.matches(sub, j, endTable) {
            limit = after.lowerBound + j
            break
        }
        if let c = captions(in: after.lowerBound..<limit).first {
            return conv.convert(c, ctx: CellContext())
        }
        return nil
    }

    private func findNotes(_ s: [Character], in r: Range<Int>) -> [String] {
        guard !r.isEmpty else { return [] }
        let region = Array(s[r])
        let tok = Array("\\begin{tablenotes}")
        for j in 0..<region.count where Latex.matches(region, j, tok) {
            var sc = LatexScanner(region)
            sc.i = j + tok.count
            _ = sc.readOptional()
            guard let (end, _) = Latex.findEnd(of: "tablenotes", in: region, from: sc.i) else { return [] }
            let body = String(region[sc.i..<end])
            let conv = InlineConverter(macros: macros)
            return InlineConverter.items(body).map { conv.convert($0, ctx: CellContext()) }
        }
        return []
    }

    // MARK: - Column spec

    static func parseColumnSpec(_ spec: String, macros: [String: Macro] = [:]) -> [ColumnSpec] {
        var cols: [ColumnSpec] = []
        var pendingLeft = 0
        var pendingAlign: ColumnAlign? = nil
        var sc = LatexScanner(spec)

        func add(_ a: ColumnAlign, width: String? = nil) {
            var c = ColumnSpec(align: pendingAlign ?? a, width: width)
            c.leftRules = pendingLeft
            pendingLeft = 0
            pendingAlign = nil
            cols.append(c)
        }
        func addRule() {
            if cols.isEmpty || pendingLeft > 0 || pendingAlign != nil { pendingLeft += 1 } else { cols[cols.count - 1].rightRules += 1 }
        }

        while let c = sc.peek {
            switch c {
            case "|":
                sc.i += 1
                addRule()
            case "l", "L": sc.i += 1; add(.left)
            case "c", "C": sc.i += 1; add(.center)
            case "r", "R": sc.i += 1; add(.right)
            case "p", "m", "b":
                sc.i += 1
                add(.justify, width: sc.readBraced())
            case "X", "J":
                sc.i += 1
                add(.justify)
            case "S", "s":
                sc.i += 1
                _ = sc.readOptional()
                add(.center)
            case "D":
                sc.i += 1
                _ = sc.readBraced(); _ = sc.readBraced(); _ = sc.readBraced()
                add(.center)
            case "d":
                sc.i += 1
                _ = sc.readBraced()
                add(.center)
            case "w", "W":
                sc.i += 1
                let a = sc.readBraced() ?? "l"
                let w = sc.readBraced()
                add(a.contains("r") ? .right : a.contains("c") ? .center : .left, width: w)
            case "@", "!":
                sc.i += 1
                let content = sc.readBraced() ?? ""
                if content.contains("vline") || content.contains("vrule") { addRule() }
            case ">":
                sc.i += 1
                let content = sc.readBraced() ?? ""
                if content.contains("\\centering") { pendingAlign = .center } else if content.contains("\\raggedleft") { pendingAlign = .right } else if content.contains("\\raggedright") { pendingAlign = .left }
            case "<":
                sc.i += 1
                _ = sc.readBraced()
            case "*":
                sc.i += 1
                let n = Int((sc.readBraced() ?? "1").trimmingCharacters(in: .whitespaces)) ?? 1
                let inner = sc.readBraced() ?? ""
                let rep = String(repeating: inner, count: max(0, min(n, 200)))
                let rest = String(sc.s[sc.i...])
                sc = LatexScanner(rep + rest)
            case "Q":
                // tabularray-style Q[c] / X[l]
                sc.i += 1
                let o = sc.readOptional() ?? ""
                add(o.contains("r") ? .right : o.contains("l") ? .left : .center)
            case "\\":
                // a \newcolumntype'd macro or something exotic: treat as centered column
                _ = sc.readCommand()
                add(.center)
            case "{", "[":
                if c == "{" { _ = sc.readBraced() } else { _ = sc.readOptional() }
            default:
                sc.i += 1
                if c.isLetter { add(.center) }
            }
        }
        if pendingLeft > 0, !cols.isEmpty { cols[cols.count - 1].rightRules += pendingLeft }
        return cols
    }

    // MARK: - Body

    private func parseTable(_ loc: Located, _ s: [Character]) -> ParsedTable {
        let columns = Self.parseColumnSpec(loc.specText, macros: macros)
        var body = Array(s[loc.bodyStart..<loc.bodyEnd])
        if loc.env.hasPrefix("longtable") || loc.env == "xltabular" || loc.env == "longtabu" {
            body = Self.reorderLongtable(body)
        }
        let chunks = Self.splitRows(body)
        let conv = InlineConverter(macros: macros)

        var rows: [Row] = []
        var pendingRules: [Rule] = []
        var pendingSpace = 0.0
        var pendingRowColor: String? = nil

        for (ci, chunk) in chunks.enumerated() {
            var sc = LatexScanner(chunk.text)
            let (rules, space, rowColor) = Self.readLeadingRules(&sc, existing: &pendingRules)
            _ = rules
            pendingSpace += space
            if let rowColor { pendingRowColor = rowColor }
            let rest = String(sc.s[sc.i...])
            let isLast = ci == chunks.count - 1
            let restTrim = rest.trimmingCharacters(in: .whitespacesAndNewlines)
            if restTrim.isEmpty && (isLast || !chunk.endedWithBreak) {
                continue  // only rules in this chunk (e.g. trailing \bottomrule)
            }
            let cellTexts = Self.splitCells(Array(rest))
            var cells: [Cell] = []
            let rowCtx = CellContext()
            for raw in cellTexts {
                cells.append(parseCell(raw, conv: conv, rowCtx: rowCtx))
            }
            var row = Row(cells: cells, rulesAbove: pendingRules, extraSpaceAbove: pendingSpace)
            row.background = rowCtx.rowColor ?? pendingRowColor
            if chunk.spaceAfter > 0 { pendingSpace = chunk.spaceAfter } else { pendingSpace = 0 }
            pendingRules = []
            pendingRowColor = nil
            rows.append(row)
        }

        // Drop fully empty rows with no rules (artifacts of `\\[-1ex]`), but keep their rules.
        var cleaned: [Row] = []
        var carry: [Rule] = []
        for var r in rows {
            if r.cells.allSatisfy({ $0.isEmpty && $0.colspan == 1 }) && r.cells.count <= 1 {
                carry += r.rulesAbove
                continue
            }
            if !carry.isEmpty { r.rulesAbove = carry + r.rulesAbove; carry = [] }
            cleaned.append(r)
        }
        pendingRules = carry + pendingRules
        assignLevels(&cleaned, &pendingRules)
        return ParsedTable(columns: columns, rows: cleaned, trailingRules: pendingRules, caption: nil, envName: loc.env)
    }

    private func assignLevels(_ rows: inout [Row], _ trailing: inout [Rule]) {
        func assign(_ rules: inout [Rule]) {
            var level = 0
            var used: [(Int, Int)] = []
            for i in rules.indices {
                let r = rules[i]
                if r.from == nil {
                    if i > 0 { level += 1 }
                    used = [(1, Int.max)]
                } else {
                    let a = r.from!, b = r.to ?? r.from!
                    if used.contains(where: { !($0.1 < a || $0.0 > b) }) {
                        level += 1
                        used = []
                    }
                    used.append((a, b))
                }
                rules[i].level = level
            }
        }
        for i in rows.indices { assign(&rows[i].rulesAbove) }
        assign(&trailing)
    }

    struct Chunk {
        var text: String
        var endedWithBreak: Bool
        var spaceAfter: Double  // from \\[Xpt], in em
    }

    /// Split body at top-level `\\` / `\tabularnewline`.
    static func splitRows(_ s: [Character]) -> [Chunk] {
        var chunks: [Chunk] = []
        var depth = 0
        var envDepth = 0
        var start = 0
        var k = 0
        let beginTok = Array("\\begin{"), endTok = Array("\\end{")
        while k < s.count {
            let c = s[k]
            if c == "{" { depth += 1; k += 1; continue }
            if c == "}" { depth -= 1; k += 1; continue }
            if c == "\\" {
                if Latex.matches(s, k, beginTok) { envDepth += 1; k += 7; continue }
                if Latex.matches(s, k, endTok) { envDepth -= 1; k += 5; continue }
                let isBreak = k + 1 < s.count && s[k + 1] == "\\"
                let tabNL = Latex.matches(s, k, Array("\\tabularnewline"))
                if (isBreak || tabNL) && depth <= 0 && envDepth <= 0 {
                    let text = String(s[start..<k])
                    var sc = LatexScanner(s)
                    sc.i = k + (isBreak ? 2 : 15)
                    sc.skipStar()
                    var space = 0.0
                    let save = sc.i
                    sc.skipSpaces()
                    if sc.peek == "[" {
                        space = dimensionToEm(sc.readOptional() ?? "")
                    } else {
                        sc.i = save
                    }
                    chunks.append(Chunk(text: text, endedWithBreak: true, spaceAfter: space))
                    k = sc.i
                    start = k
                    continue
                }
                k += 2
                continue
            }
            k += 1
        }
        if start < s.count {
            chunks.append(Chunk(text: String(s[start...]), endedWithBreak: false, spaceAfter: 0))
        }
        return chunks
    }

    /// Longtable: keep first head (or head), body, last foot (or foot), in that order.
    static func reorderLongtable(_ s: [Character]) -> [Character] {
        let markers = ["\\endfirsthead", "\\endhead", "\\endfoot", "\\endlastfoot"]
        var segments: [(String?, [Character])] = []
        var start = 0
        var k = 0
        while k < s.count {
            if s[k] == "\\" {
                var hit: String? = nil
                for m in markers where Latex.matches(s, k, Array(m)) {
                    let next = k + m.count < s.count ? s[k + m.count] : " "
                    if !next.isLetter { hit = m }
                }
                if let hit {
                    segments.append((hit, Array(s[start..<k])))
                    k += hit.count
                    start = k
                    continue
                }
                k += 2
                continue
            }
            k += 1
        }
        let tail = Array(s[start...])
        guard !segments.isEmpty else { return s }
        func seg(_ m: String) -> [Character]? { segments.first(where: { $0.0 == m })?.1 }
        let head = seg("\\endfirsthead") ?? seg("\\endhead") ?? []
        let foot = seg("\\endlastfoot") ?? seg("\\endfoot") ?? []
        return head + tail + foot
    }

    /// Split a row at top-level `&` (ignoring `\&`).
    static func splitCells(_ s: [Character]) -> [String] {
        var cells: [String] = []
        var depth = 0, envDepth = 0
        var start = 0
        var k = 0
        let beginTok = Array("\\begin{"), endTok = Array("\\end{")
        var inMath = false
        while k < s.count {
            let c = s[k]
            if c == "\\" {
                if Latex.matches(s, k, beginTok) { envDepth += 1; k += 7; continue }
                if Latex.matches(s, k, endTok) { envDepth -= 1; k += 5; continue }
                k += 2
                continue
            }
            if c == "{" { depth += 1 } else if c == "}" { depth -= 1 } else if c == "$" { inMath.toggle() } else if c == "&" && depth <= 0 && envDepth <= 0 && !inMath {
                cells.append(String(s[start..<k]))
                start = k + 1
            }
            k += 1
        }
        cells.append(start < s.count ? String(s[start...]) : "")
        return cells
    }

    static func dimensionToEm(_ d: String) -> Double {
        let t = d.trimmingCharacters(in: .whitespaces)
        let num = Double(t.prefix(while: { $0.isNumber || $0 == "." || $0 == "-" })) ?? 0
        if t.hasSuffix("pt") { return num / 10 }
        if t.hasSuffix("ex") { return num * 0.43 }
        if t.hasSuffix("em") { return num }
        if t.hasSuffix("mm") { return num * 0.28 }
        if t.hasSuffix("cm") { return num * 2.8 }
        if t.hasSuffix("in") { return num * 7.2 }
        if t.hasPrefix("\\") { return 0.3 }
        return num / 10
    }

    /// Consumes rule commands at the start of a row. Returns rules added, vertical space (em), row color.
    static func readLeadingRules(_ sc: inout LatexScanner, existing rules: inout [Rule]) -> ([Rule], Double, String?) {
        var added: [Rule] = []
        var space = 0.0
        var rowColor: String? = nil
        func push(_ r: Rule) { rules.append(r); added.append(r) }
        func range(_ s: String) -> (Int, Int)? {
            let p = s.split(separator: "-").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
            if p.count == 2 { return (p[0], p[1]) }
            if p.count == 1 { return (p[0], p[0]) }
            return nil
        }
        while true {
            sc.skipSpaces()
            guard sc.peek == "\\" else { break }
            let save = sc.i
            let name = sc.readCommand() ?? ""
            switch name {
            case "hline", "firsthline", "lasthline":
                push(Rule(kind: .hline))
            case "Xhline", "specialrule":
                let w = sc.readBraced() ?? ""
                if name == "specialrule" { _ = sc.readBraced(); _ = sc.readBraced() }
                push(Rule(kind: dimensionToEm(w) > 0.06 ? .thick : .hline))
            case "toprule", "bottomrule", "heavyrule":
                _ = sc.readOptional()
                push(Rule(kind: .thick))
            case "midrule":
                _ = sc.readOptional()
                push(Rule(kind: .thin))
            case "cline", "cmidrule", "cdashline", "Cline":
                _ = sc.readOptional()
                let trim = sc.readParen() ?? ""
                if name == "Cline" { _ = sc.readOptional() }
                let arg = sc.readBraced() ?? ""
                if name == "Cline" { _ = sc.readBraced() }
                if let (a, b) = range(arg) {
                    var r = Rule(kind: name == "cdashline" ? .dashed : (name == "cmidrule" ? .thin : .hline), from: a, to: b)
                    r.trimLeft = trim.contains("l")
                    r.trimRight = trim.contains("r")
                    push(r)
                }
            case "hdashline":
                push(Rule(kind: .dashed))
            case "addlinespace":
                let o = sc.readOptional()
                space += o.map(dimensionToEm) ?? 0.5
            case "noalign":
                let inner = sc.readBraced() ?? ""
                var sub = LatexScanner(inner)
                let r = readLeadingRules(&sub, existing: &rules)
                added += r.0
                space += r.1
                if inner.contains("skip") { space += 0.4 }
            case "rowcolor":
                let model = sc.readOptional()
                rowColor = Colors.css(sc.readBraced() ?? "", model: model)
                _ = sc.readOptional()
            case "vspace", "smallskip", "medskip", "bigskip":
                sc.skipStar()
                if name == "vspace" { space += max(0, dimensionToEm(sc.readBraced() ?? "")) } else { space += 0.4 }
            case "hhline":
                _ = sc.readBraced()
                push(Rule(kind: .hline))
            case "morecmidrules", "arrayrulecolor", "rowfont", "relax", "hiderowcolors", "showrowcolors", "pagebreak", "nopagebreak", "noindent", "centering":
                if name == "arrayrulecolor" { _ = sc.readOptional(); _ = sc.readBraced() }
                if name == "rowfont" { _ = sc.readOptional(); _ = sc.readBraced() }
            default:
                sc.i = save
                return (added, space, rowColor)
            }
        }
        return (added, space, rowColor)
    }

    // MARK: - Cells

    private func parseCell(_ raw: String, conv: InlineConverter, rowCtx: CellContext) -> Cell {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        var colspan = 1, rowspan = 1
        var align: ColumnAlign? = nil
        var spec: [ColumnSpec]? = nil

        var sc = LatexScanner(text)
        if sc.hasPrefix("\\multicolumn") {
            _ = sc.readCommand()
            colspan = max(1, Int((sc.readBraced() ?? "1").trimmingCharacters(in: .whitespaces)) ?? 1)
            let specText = sc.readBraced() ?? "c"
            let parsed = Self.parseColumnSpec(specText)
            spec = parsed
            align = parsed.first?.align
            let content = sc.readBraced() ?? ""
            let trailing = String(sc.s[sc.i...])
            text = (content + trailing).trimmingCharacters(in: .whitespacesAndNewlines)
            sc = LatexScanner(text)
        }
        // Skip leading size/style declarations to find \multirow
        if sc.hasPrefix("\\multirow") {
            _ = sc.readCommand()
            let n = Int((sc.readBraced() ?? "1").trimmingCharacters(in: .whitespaces)) ?? 1
            _ = sc.readOptional()
            _ = sc.readBraced()
            _ = sc.readOptional()
            let content = sc.readBraced() ?? ""
            let trailing = String(sc.s[sc.i...])
            if n > 1 { rowspan = n }
            text = (content + trailing).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let ctx = CellContext()
        let html = conv.convert(text, ctx: ctx).trimmingCharacters(in: .whitespaces)
        if let rc = ctx.rowColor { rowCtx.rowColor = rc }
        if let a = ctx.align { align = a }
        return Cell(html: html, colspan: colspan, rowspan: rowspan, align: align, spec: spec, background: ctx.cellColor, isEmpty: html.isEmpty)
    }

    // MARK: - Macros

    /// Collects simple user macros: \newcommand{\x}[n]{body}, \def\x#1{body}, \DeclareMathOperator.
    static func collectMacros(_ text: String) -> [String: Macro] {
        guard text.contains("command") || text.contains("\\def") || text.contains("DeclareMathOperator") else { return [:] }
        var out: [String: Macro] = [:]
        var sc = LatexScanner(text)
        while !sc.atEnd {
            guard sc.peek == "\\" else { sc.i += 1; continue }
            let name = sc.readCommand() ?? ""
            switch name {
            case "newcommand", "renewcommand", "providecommand", "DeclareRobustCommand":
                sc.skipStar()
                guard let rawName = sc.readArg() else { continue }
                let macroName = rawName.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\\"))
                let n = Int(sc.readOptional() ?? "0") ?? 0
                _ = sc.readOptional()  // default for optional first arg
                if let body = sc.readBraced(), !macroName.isEmpty { out[macroName] = Macro(nargs: n, body: body) }
            case "def", "gdef", "edef":
                sc.skipSpaces()
                guard sc.peek == "\\" else { continue }
                let macroName = sc.readCommand() ?? ""
                var n = 0
                while let c = sc.peek, c != "{" {
                    if c == "#" { n += 1 }
                    sc.i += 1
                }
                if let body = sc.readBraced(), !macroName.isEmpty { out[macroName] = Macro(nargs: n, body: body) }
            case "DeclareMathOperator":
                sc.skipStar()
                guard let rawName = sc.readArg() else { continue }
                let macroName = rawName.trimmingCharacters(in: CharacterSet(charactersIn: "\\ "))
                if let body = sc.readBraced() { out[macroName] = Macro(nargs: 0, body: "\\mathrm{\(body)}") }
            default:
                continue
            }
        }
        return out
    }
}
