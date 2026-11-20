import Foundation

public enum HTMLRenderer {
    /// Inner HTML for the quick view (everything that goes inside #root).
    public static func bodyHTML(_ result: ParseResult) -> String {
        if result.tables.isEmpty {
            return "<div class=\"empty\">No <code>tabular</code> environment found in this file.<br><span>Try the PDF or Source view.</span></div>"
        }
        var out = ""
        var tableNo = 0
        for t in result.tables {
            out += "<div class=\"paper\">"
            if let cap = t.caption {
                tableNo += 1
                out += "<div class=\"caption\">Table \(tableNo): \(cap)</div>"
            }
            out += tableHTML(t, nested: false)
            if !t.notes.isEmpty {
                out += "<div class=\"notes\">" + t.notes.map { "<div>\($0)</div>" }.joined() + "</div>"
            }
            out += "</div>"
        }
        return out
    }

    static func tableHTML(_ t: ParsedTable, nested: Bool) -> String {
        let ncols = max(t.columns.count, t.rows.map { $0.cells.reduce(0) { $0 + $1.colspan } }.max() ?? 0)
        var covered = [Int](repeating: -1, count: ncols + 64)  // last row index covered by a rowspan
        var html = nested ? "<table class=\"tex nested\">" : "<table class=\"tex\">"

        for (ri, row) in t.rows.enumerated() {
            let isLast = ri == t.rows.count - 1
            let nextHasRules = !isLast && !t.rows[ri + 1].rulesAbove.isEmpty
            var tr = "<tr"
            if let bg = row.background { tr += " style=\"background-color:\(bg)\"" }
            tr += ">"
            var col = 0
            for cell in row.cells {
                // Skip empty cells sitting under a \multirow from above.
                if col < covered.count, covered[col] >= ri, cell.isEmpty {
                    col += cell.colspan
                    continue
                }
                let c0 = col, c1 = col + cell.colspan - 1
                col += cell.colspan
                if cell.rowspan > 1 {
                    for k in c0...c1 where k < covered.count { covered[k] = ri + cell.rowspan - 1 }
                }
                tr += cellHTML(cell, c0: c0, c1: c1, row: row, table: t, isLast: isLast, nextHasRules: nextHasRules)
            }
            // Pad short rows so rules span the full width.
            while col < ncols {
                if col < covered.count, covered[col] >= ri { col += 1; continue }
                let empty = Cell(html: "", isEmpty: true)
                tr += cellHTML(empty, c0: col, c1: col, row: row, table: t, isLast: isLast, nextHasRules: nextHasRules)
                col += 1
            }
            tr += "</tr>"
            html += tr
        }
        html += "</table>"
        return html
    }

    private static func cellHTML(_ cell: Cell, c0: Int, c1: Int, row: Row, table t: ParsedTable, isLast: Bool, nextHasRules: Bool) -> String {
        let colSpec: ColumnSpec? = c0 < t.columns.count ? t.columns[c0] : nil
        let align = cell.align ?? colSpec?.align ?? .left
        var styles: [String] = []
        switch align {
        case .left: break
        case .center: styles.append("text-align:center")
        case .right: styles.append("text-align:right")
        case .justify:
            styles.append("white-space:normal")
            if cell.colspan == 1, let w = colSpec?.width {
                styles.append("min-width:\(fmt(widthEm(w)))em;max-width:\(fmt(widthEm(w)))em")
            } else {
                styles.append("min-width:6em")
            }
        }

        // Vertical rules
        let leftRules: Int
        let rightRules: Int
        if let spec = cell.spec, let f = spec.first {
            leftRules = c0 == 0 || f.leftRules > 0 ? f.leftRules : 0
            rightRules = spec.last?.rightRules ?? 0
        } else {
            leftRules = c0 == 0 ? (t.columns.first?.leftRules ?? 0) : 0
            rightRules = c1 < t.columns.count ? t.columns[c1].rightRules : 0
        }
        if leftRules > 0 { styles.append("border-left:\(leftRules > 1 ? "3px double" : "1px solid") currentColor") }
        if rightRules > 0 { styles.append("border-right:\(rightRules > 1 ? "3px double" : "1px solid") currentColor") }

        // Horizontal rules drawn as background layers so partial (cmidrule) trims work.
        var layers: [(size: String, pos: String)] = []
        var topLevels = -1
        for r in row.rulesAbove where overlaps(r, c0, c1) {
            layers.append(layer(r, c0: c0, c1: c1, top: true))
            topLevels = max(topLevels, r.level)
        }
        var bottomLevels = -1
        if isLast {
            for r in t.trailingRules where overlaps(r, c0, c1) {
                layers.append(layer(r, c0: c0, c1: c1, top: false))
                bottomLevels = max(bottomLevels, r.level)
            }
        }
        if !layers.isEmpty {
            styles.append("background-image:" + layers.map { _ in "linear-gradient(currentColor,currentColor)" }.joined(separator: ","))
            styles.append("background-size:" + layers.map { $0.size }.joined(separator: ","))
            styles.append("background-position:" + layers.map { $0.pos }.joined(separator: ","))
            styles.append("background-repeat:no-repeat")
        }

        // Spacing: booktabs-ish padding around rules
        var padTop = 0.12
        var padBottom = 0.12
        if !row.rulesAbove.isEmpty { padTop += 0.3 + Double(max(0, topLevels)) * 0.18 }
        if row.extraSpaceAbove > 0 { padTop += row.extraSpaceAbove }
        if nextHasRules { padBottom += 0.18 }
        if isLast && !t.trailingRules.isEmpty { padBottom += 0.3 + Double(max(0, bottomLevels)) * 0.18 }
        styles.append("padding-top:\(fmt(padTop))em;padding-bottom:\(fmt(padBottom))em")
        if let bg = cell.background { styles.append("background-color:\(bg)") }

        var td = "<td"
        if cell.colspan > 1 { td += " colspan=\"\(cell.colspan)\"" }
        if cell.rowspan > 1 { td += " rowspan=\"\(cell.rowspan)\"" }
        td += " style=\"\(styles.joined(separator: ";"))\">"
        td += cell.html
        td += "</td>"
        return td
    }

    private static func overlaps(_ r: Rule, _ c0: Int, _ c1: Int) -> Bool {
        guard let from = r.from else { return true }
        let to = r.to ?? from
        return !(to - 1 < c0 || from - 1 > c1)
    }

    private static func layer(_ r: Rule, c0: Int, c1: Int, top: Bool) -> (size: String, pos: String) {
        let thickness: String
        switch r.kind {
        case .thick: thickness = "0.08em"
        case .thin: thickness = "0.05em"
        case .hline, .dashed: thickness = "0.04em"
        }
        let trim = 0.3
        let l = (r.trimLeft && r.from == c0 + 1) ? trim : 0
        let rt = (r.trimRight && (r.to ?? r.from) == c1 + 1) ? trim : 0
        let offset = Double(r.level) * 0.18
        let size = "calc(100% - \(fmt(l + rt))em) max(1px,\(thickness))"
        let pos = "left \(fmt(l))em \(top ? "top" : "bottom") \(fmt(offset))em"
        return (size, pos)
    }

    private static func widthEm(_ w: String) -> Double {
        let t = w.trimmingCharacters(in: .whitespaces)
        for rel in ["\\textwidth", "\\linewidth", "\\columnwidth", "\\hsize"] where t.contains(rel) {
            let f = Double(t.replacingOccurrences(of: rel, with: "").trimmingCharacters(in: .whitespaces)) ?? 1
            return f * 34
        }
        let v = TableParser.dimensionToEm(t)
        return v > 0 ? v : 8
    }

    private static func fmt(_ d: Double) -> String { String(format: "%.2f", d) }

    // MARK: - Page shell

    public static let css = """
    :root { color-scheme: light dark; }
    html, body { margin: 0; padding: 0; }
    body { background: #e9e9ec; font-family: "LMRoman", "Latin Modern Roman", "CMU Serif", "Computer Modern", "Times New Roman", serif;
           color: #111; -webkit-font-smoothing: antialiased; }
    @media (prefers-color-scheme: dark) { body { background: #2a2a2d; } }
    #root { padding: 18px; min-width: max-content; }
    .paper { background: #fff; color: #111; box-shadow: 0 1px 3px rgba(0,0,0,.18), 0 6px 20px rgba(0,0,0,.08);
             border-radius: 3px; padding: 22px 26px; margin: 0 auto 18px auto; width: max-content; font-size: 15px; }
    .caption { text-align: center; margin: 0 auto 10px auto; max-width: 42em; }
    .notes { margin-top: 8px; font-size: 0.85em; max-width: 60em; }
    table.tex { border-collapse: separate; border-spacing: 0; margin: 0 auto; font-variant-numeric: lining-nums tabular-nums; }
    table.tex td { padding-left: 0.5em; padding-right: 0.5em; white-space: nowrap; vertical-align: middle; line-height: 1.2; }
    table.tex.nested { display: inline-table; vertical-align: middle; margin: 0; }
    table.tex.nested td { padding-left: 0.2em; padding-right: 0.2em; }
    .stack { display: inline-block; vertical-align: middle; line-height: 1.15; }
    .sc { font-variant: small-caps; }
    .up { font-style: normal; }
    .math i { font-style: italic; }
    .ovl { text-decoration: overline; }
    .phantom { visibility: hidden; }
    .fbox { border: 1px solid currentColor; padding: 0 2px; }
    .muted { color: #888; }
    code { font-family: "LMMono", "Latin Modern Mono", Menlo, monospace; font-size: 0.95em; }
    sup, sub { font-size: 0.7em; line-height: 0; }
    .empty { margin: 60px auto; text-align: center; color: #777; font: 14px -apple-system, sans-serif; }
    .empty span { font-size: 12px; color: #999; }
    """

    /// A standalone HTML document (used by the CLI and as the app's initial page).
    public static func page(body: String, extraHead: String = "") -> String {
        """
        <!doctype html><html><head><meta charset="utf-8">
        <style>\(css)</style>\(extraHead)
        </head><body><div id="root">\(body)</div></body></html>
        """
    }
}
