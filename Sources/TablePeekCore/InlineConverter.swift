import Foundation

/// Side-channel state a cell's content can set (colors, alignment overrides).
final class CellContext {
    var cellColor: String?
    var rowColor: String?
    var align: ColumnAlign?
}

struct Macro {
    var nargs: Int
    var body: String
}

/// Best-effort LaTeX (inline content of a table cell) -> HTML converter.
struct InlineConverter {
    var macros: [String: Macro] = [:]

    func convert(_ text: String, ctx: CellContext, math: Bool = false, depth: Int = 0) -> String {
        if depth > 40 { return Latex.htmlEscape(text) }
        var sc = LatexScanner(text)
        var out = ""

        let sub: (String?, Bool?) -> String = { t, m in
            guard let t else { return "" }
            return convert(t, ctx: ctx, math: m ?? math, depth: depth + 1)
        }

        while let c = sc.peek {
            switch c {
            case "\\":
                if handleCommand(&sc, &out, ctx: ctx, math: math, depth: depth, sub: sub) { continue }
            case "{":
                out += sub(sc.readBraced(), nil)
            case "}":
                sc.i += 1
            case "$":
                sc.i += 1
                let display = sc.peek == "$"
                if display { sc.i += 1 }
                let start = sc.i
                while sc.i < sc.s.count {
                    if sc.s[sc.i] == "\\" { sc.i += 2; continue }
                    if sc.s[sc.i] == "$" { break }
                    sc.i += 1
                }
                let inner = String(sc.s[start..<min(sc.i, sc.s.count)])
                sc.i += display ? 2 : 1
                if math {
                    out += sub(inner, false)
                } else {
                    out += "<span class=\"math\">" + sub(inner, true) + "</span>"
                }
            case "~":
                sc.i += 1
                out += "&nbsp;"
            case "-":
                var n = 0
                while sc.peek == "-" { n += 1; sc.i += 1 }
                if math { out += String(repeating: "\u{2212}", count: n) } else {
                    out += n >= 3 ? "\u{2014}" : n == 2 ? "\u{2013}" : "-"
                }
            case "`":
                sc.i += 1
                if sc.peek == "`" { sc.i += 1; out += "\u{201C}" } else { out += "\u{2018}" }
            case "'":
                sc.i += 1
                if math { out += "\u{2032}" } else if sc.peek == "'" { sc.i += 1; out += "\u{201D}" } else { out += "\u{2019}" }
            case "^", "_":
                sc.i += 1
                guard math else { out.append(c); continue }
                let arg = sc.readArg() ?? ""
                let trimmed = arg.trimmingCharacters(in: .whitespaces)
                if c == "^" && (trimmed == "\\circ" || trimmed == "{\\circ}") {
                    out += "°"
                } else if c == "^" && (trimmed == "\\prime") {
                    out += "\u{2032}"
                } else {
                    let tag = c == "^" ? "sup" : "sub"
                    out += "<\(tag)>" + sub(arg, nil) + "</\(tag)>"
                }
            case "&":
                sc.i += 1
                out += "&amp;"
            case "<", ">", "=":
                sc.i += 1
                let ent = c == "<" ? "&lt;" : c == ">" ? "&gt;" : "="
                out += math ? "\u{2005}\(ent)\u{2005}" : ent
            case "#":
                sc.i += 1
            default:
                if c.isWhitespace {
                    sc.skipSpaces()
                    if !math, !out.isEmpty, !out.hasSuffix(" ") { out += " " }
                } else if math && c.isLetter {
                    let start = sc.i
                    while let p = sc.peek, p.isLetter { sc.i += 1 }
                    out += "<i>" + Latex.htmlEscape(String(sc.s[start..<sc.i])) + "</i>"
                } else if math && c == "*" {
                    sc.i += 1
                    out += "*"
                } else {
                    sc.i += 1
                    out.append(c)
                }
            }
        }
        return out
    }

    // MARK: - Commands

    /// Returns true if it consumed something.
    private func handleCommand(
        _ sc: inout LatexScanner, _ out: inout String, ctx: CellContext, math: Bool, depth: Int,
        sub: (String?, Bool?) -> String
    ) -> Bool {
        let save = sc.i
        guard let name = sc.readCommand() else { sc.i += 1; return true }
        let isWord = name.first?.isLetter == true || name.first == "@"
        if isWord { sc.skipInlineSpacesAfterControlWord() }
        func s(_ t: String?) -> String { sub(t, nil) }
        func arg() -> String? { sc.readArg() }
        func opt() -> String? { sc.readOptional() }
        func wrapRest(_ open: String, _ close: String) {
            let rest = String(sc.s[min(sc.i, sc.s.count)...])
            out += open + convert(rest, ctx: ctx, math: math, depth: depth + 1) + close
            sc.i = sc.s.count
        }

        // Single-character control symbols
        if !isWord {
            switch name {
            case "\\":
                sc.skipStar()
                _ = sc.readOptional()
                out += "<br>"
            case "&": out += "&amp;"
            case "%", "$", "#", "_", "{", "}": out += name
            case ",": out += "\u{2009}"
            case ";", ":", ">": out += "\u{2005}"
            case " ": out += " "
            case "!", "/", "-", "@": break
            case "|": out += "\u{2016}"
            case "(", "[":
                // inline / display math \( ... \)
                let close = name == "(" ? "\\)" : "\\]"
                let start = sc.i
                while sc.i < sc.s.count, !sc.hasPrefix(close) {
                    sc.i += sc.s[sc.i] == "\\" ? 2 : 1
                }
                let inner = String(sc.s[start..<min(sc.i, sc.s.count)])
                sc.i += 2
                out += math ? sub(inner, true) : "<span class=\"math\">" + sub(inner, true) + "</span>"
            case ")", "]": break
            case "'", "`", "^", "\"", "~", "=", ".":
                out += accent(name, s(arg()))
            default:
                out += Latex.htmlEscape(name)
            }
            return true
        }

        if let sym = Self.symbols[name] {
            if math, Self.relations.contains(name) {
                out += "\u{2005}\(sym)\u{2005}"
            } else {
                out += sym
            }
            return true
        }

        switch name {
        // --- one-arg formatting
        case "textbf", "mathbf", "boldsymbol", "bm", "pmb": out += "<b>" + s(arg()) + "</b>"
        case "textit", "emph", "textsl", "mathit": out += "<i>" + s(arg()) + "</i>"
        case "underline", "uline", "ul": out += "<u>" + s(arg()) + "</u>"
        case "texttt", "mathtt": out += "<code>" + s(arg()) + "</code>"
        case "textsc": out += "<span class=\"sc\">" + s(arg()) + "</span>"
        case "textsuperscript", "sym", "tnote", "textsu":
            out += "<sup>" + sub(arg(), false) + "</sup>"
        case "textsubscript": out += "<sub>" + sub(arg(), false) + "</sub>"
        case "text", "textrm", "textnormal", "textup", "textmd", "textsf", "mbox", "hbox", "mathrm",
             "mathsf", "mathnormal", "operatorname", "textrm*", "intertext":
            sc.skipStar()
            out += "<span class=\"up\">" + sub(arg(), false) + "</span>"
        case "mathbb":
            out += Self.doubleStruck(arg() ?? "")
        case "mathcal", "mathscr", "mathfrak":
            out += s(arg())
        case "bar", "overline": out += "<span class=\"ovl\">" + s(arg()) + "</span>"
        case "hat", "widehat": out += s(arg()) + "\u{0302}"
        case "tilde", "widetilde": out += s(arg()) + "\u{0303}"
        case "dot": out += s(arg()) + "\u{0307}"
        case "ddot": out += s(arg()) + "\u{0308}"
        case "vec": out += s(arg()) + "\u{20D7}"
        case "sqrt":
            _ = opt()
            out += "\u{221A}<span class=\"ovl\">" + s(arg()) + "</span>"
        case "frac", "dfrac", "tfrac", "nicefrac", "sfrac":
            let a = s(arg()), b = s(arg())
            out += "<sup>\(a)</sup>\u{2044}<sub>\(b)</sub>"
        case "binom": out += "(" + s(arg()) + " choose " + s(arg()) + ")"

        // --- containers whose last arg is content
        case "makecell", "thead", "shortstack", "Centerstack", "Longstack", "Shortstack", "specialcell", "stackanchor", "tabularcell", "makegapedcells":
            sc.skipStar()
            let o = opt() ?? (name == "shortstack" ? "c" : "c")
            let align = o.contains("l") ? "left" : o.contains("r") ? "right" : "center"
            out += "<span class=\"stack\" style=\"text-align:\(align)\">" + s(arg()) + "</span>"
        case "makebox", "framebox":
            _ = opt(); _ = opt()
            out += (name == "framebox" ? "<span class=\"fbox\">" : "<span>") + s(arg()) + "</span>"
        case "fbox", "boxed": out += "<span class=\"fbox\">" + s(arg()) + "</span>"
        case "parbox":
            _ = opt(); _ = opt(); _ = opt(); _ = arg()
            out += s(arg())
        case "raisebox":
            _ = arg(); _ = opt(); _ = opt()
            out += s(arg())
        case "rotatebox":
            _ = opt(); _ = arg()
            out += s(arg())
        case "resizebox":
            sc.skipStar(); _ = arg(); _ = arg()
            out += s(arg())
        case "scalebox":
            _ = arg(); _ = opt()
            out += s(arg())
        case "adjustbox":
            _ = arg()
            out += s(arg())
        case "href": _ = arg(); out += "<u>" + s(arg()) + "</u>"
        case "url", "nolinkurl", "path": out += "<code>" + Latex.htmlEscape(arg() ?? "") + "</code>"
        case "textcolor":
            _ = opt()
            let col = Colors.css(arg() ?? "")
            out += "<span style=\"color:\(col)\">" + s(arg()) + "</span>"
        case "colorbox":
            _ = opt()
            let col = Colors.css(arg() ?? "")
            out += "<span style=\"background:\(col)\">" + s(arg()) + "</span>"
        case "multicolumn":
            _ = arg(); _ = arg()
            out += s(arg())
        case "multirow", "multirowcell":
            _ = arg(); _ = opt(); _ = arg(); _ = opt()
            out += s(arg())
        case "footnote", "tablefootnote", "footnotetext":
            _ = opt(); _ = arg()
            out += "<sup>*</sup>"
        case "phantom", "hphantom":
            out += "<span class=\"phantom\">" + s(arg()) + "</span>"
        case "vphantom", "label", "index", "nocite", "hyperlink", "hypertarget", "captionsetup", "sisetup",
             "arrayrulecolor", "glsadd", "setcounter", "addtocounter":
            if name == "hyperlink" || name == "hypertarget" { _ = arg(); out += s(arg()); break }
            if name == "setcounter" || name == "addtocounter" { _ = arg() }
            if name == "captionsetup" { _ = opt() }
            _ = arg()
        case "hspace", "vspace", "addvspace":
            sc.skipStar(); _ = arg()
            if name == "hspace" { out += " " }
        case "hskip", "vskip", "kern", "mskip", "mkern":
            sc.skipDimension()
        case "rule":
            _ = opt(); _ = arg(); _ = arg()
        case "setlength", "addtolength", "settowidth":
            _ = arg(); _ = arg()
        case "fontsize":
            _ = arg(); _ = arg()
        case "newcommand", "renewcommand", "providecommand", "def", "newcolumntype", "DeclareRobustCommand":
            // Definitions inside cells: skip them.
            sc.skipStar()
            _ = arg(); _ = opt(); _ = opt(); _ = arg()
        case "ref", "eqref", "autoref", "cref", "Cref", "pageref", "nameref":
            sc.skipStar()
            out += "<span class=\"muted\">[" + Latex.htmlEscape(arg() ?? "") + "]</span>"
        case "cite", "citet", "citep", "citealt", "citealp", "citeauthor", "citeyear", "parencite", "textcite", "autocite":
            sc.skipStar(); _ = opt(); _ = opt()
            out += "<span class=\"muted\">(" + Latex.htmlEscape(arg() ?? "") + ")</span>"
        case "num", "numlist", "numrange":
            _ = opt()
            out += Self.formatNumber(arg() ?? "")
            if name == "numrange" { out += "\u{2013}" + Self.formatNumber(arg() ?? "") }
        case "SI", "qty":
            _ = opt()
            let n = Self.formatNumber(arg() ?? "")
            _ = opt()
            out += n + "\u{2009}" + Self.unit(arg() ?? "")
        case "si", "unit":
            _ = opt()
            out += Self.unit(arg() ?? "")
        case "ang":
            _ = opt()
            out += Self.formatNumber(arg() ?? "") + "°"
        case "cellcolor":
            let model = opt()
            ctx.cellColor = Colors.css(arg() ?? "", model: model)
        case "rowcolor":
            let model = opt()
            ctx.rowColor = Colors.css(arg() ?? "", model: model)
        case "color":
            let model = opt()
            let col = Colors.css(arg() ?? "", model: model)
            wrapRest("<span style=\"color:\(col)\">", "</span>")
        case "centering": ctx.align = .center
        case "raggedright", "RaggedRight", "flushleft": ctx.align = .left
        case "raggedleft", "RaggedLeft", "flushright": ctx.align = .right
        case "left", "right", "bigl", "bigr", "Bigl", "Bigr", "big", "Big", "bigg", "Bigg", "middle":
            if sc.peek == "." { sc.i += 1 }
        case "ifmmode":
            let (thenPart, elsePart) = sc.readConditional()
            out += s(math ? thenPart : elsePart)
        case "begin":
            let env = arg() ?? ""
            out += environment(env, &sc, ctx: ctx, math: math, depth: depth, sub: sub)
        case "end":
            _ = arg()

        // --- declarations (switches) that apply to the rest of the group
        case "bfseries", "bf", "boldmath":
            wrapRest("<b>", "</b>")
        case "itshape", "it", "em", "slshape", "sl":
            wrapRest("<i>", "</i>")
        case "ttfamily", "tt":
            wrapRest("<code>", "</code>")
        case "scshape", "sc":
            wrapRest("<span class=\"sc\">", "</span>")
        case "normalfont", "rmfamily", "upshape", "mdseries", "rm", "sffamily", "sf", "unboldmath":
            wrapRest("<span class=\"up\">", "</span>")
        case let size where Self.sizes[size] != nil:
            wrapRest("<span style=\"font-size:\(Self.sizes[size]!)em\">", "</span>")

        default:
            if Self.dropped.contains(name) {
                if name == "addlinespace" || name == "selectfont" { _ = opt() }
                return true
            }
            if let m = macros[name] {
                var args: [String] = []
                for _ in 0..<m.nargs { args.append(arg() ?? "") }
                var body = m.body
                for (k, a) in args.enumerated() { body = body.replacingOccurrences(of: "#\(k + 1)", with: a) }
                out += s(body)
                return true
            }
            if Self.mathFunctions.contains(name) {
                out += "<span class=\"up\">\(name)</span>"
                return true
            }
            // Unknown command: drop it, keep the content of its last braced arg.
            sc.skipStar()
            while sc.readOptional() != nil {}
            var last: String? = nil
            while let g = sc.readBracedNoSpace() { last = g }
            if let last { out += s(last) }
            _ = save
        }
        return true
    }

    private func environment(
        _ env: String, _ sc: inout LatexScanner, ctx: CellContext, math: Bool, depth: Int,
        sub: (String?, Bool?) -> String
    ) -> String {
        let bodyStart = sc.i
        guard let (bodyEnd, after) = Latex.findEnd(of: env, in: sc.s, from: bodyStart) else {
            return ""
        }
        sc.i = after
        let body = String(sc.s[bodyStart..<bodyEnd])
        if TableParser.tabularEnvs.contains(env) {
            let full = "\\begin{\(env)}" + body + "\\end{\(env)}"
            let tables = TableParser(macros: macros).parseTables(in: full, depth: depth + 1)
            return tables.map { HTMLRenderer.tableHTML($0, nested: true) }.joined()
        }
        switch env {
        case "math", "equation", "equation*", "align", "align*":
            return "<span class=\"math\">" + sub(body, true) + "</span>"
        case "itemize", "enumerate", "tablenotes":
            return Self.items(body).map { sub($0, false) }.joined(separator: "<br>")
        case "center", "minipage", "flushleft", "flushright", "small", "footnotesize":
            var b = LatexScanner(body)
            if env == "minipage" { _ = b.readOptional(); _ = b.readOptional(); _ = b.readOptional(); _ = b.readBraced() }
            return sub(String(b.s[b.i...]), nil)
        default:
            return sub(body, nil)
        }
    }

    static func items(_ body: String) -> [String] {
        var sc = LatexScanner(body)
        var items: [String] = []
        var current: String? = nil
        var buf = ""
        while !sc.atEnd {
            if sc.hasPrefix("\\item") && !(sc.peek(5)?.isLetter ?? false) {
                if current != nil { items.append(buf) }
                sc.i += 5
                let label = sc.readOptional()
                current = label ?? ""
                buf = label.map { "\\textsuperscript{\($0)} " } ?? ""
                continue
            }
            if current != nil { buf.append(sc.s[sc.i]) }
            sc.i += 1
        }
        if current != nil { items.append(buf) }
        return items.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }

    private func accent(_ a: String, _ base: String) -> String {
        let combining: [String: String] = [
            "'": "\u{0301}", "`": "\u{0300}", "^": "\u{0302}", "\"": "\u{0308}", "~": "\u{0303}",
            "=": "\u{0304}", ".": "\u{0307}",
        ]
        guard let mark = combining[a], let first = base.first else { return base }
        return (String(first) + mark).precomposedStringWithCanonicalMapping + base.dropFirst()
    }

    // MARK: - Tables of known commands

    static let sizes: [String: String] = [
        "tiny": "0.5", "scriptsize": "0.7", "footnotesize": "0.8", "small": "0.9", "normalsize": "1",
        "large": "1.2", "Large": "1.44", "LARGE": "1.73", "huge": "2.07", "Huge": "2.49",
    ]

    static let dropped: Set<String> = [
        "relax", "noindent", "indent", "strut", "mathstrut", "arraybackslash", "hfill", "hfil", "hss", "vfill",
        "null", "protect", "ignorespaces", "unskip", "smallskip", "medskip", "bigskip", "nolinebreak", "nobreak",
        "displaystyle", "textstyle", "scriptstyle", "scriptscriptstyle", "limits", "nolimits", "nonumber", "notag",
        "tabularnewline", "hline", "toprule", "midrule", "bottomrule", "addlinespace", "selectfont", "footnotemark",
        "cr", "crcr", "else", "fi", "par", "leavevmode", "newpage", "clearpage", "pagebreak", "allowbreak",
        "sloppy", "fussy", "expandafter", "makeatletter", "makeatother", "global", "long", "let", "linewidth",
        "textwidth", "columnwidth", "hsize", "centerline", "vline", "Xhline", "morecmidrules", "endhead", "endfoot",
        "endfirsthead", "endlastfoot", "noalign", "rowfont", "hdashline", "firsthline", "lasthline",
        "maketitle", "captionof", "caption",
    ]

    static let relations: Set<String> = [
        "leq", "le", "geq", "ge", "neq", "ne", "approx", "sim", "simeq", "equiv", "propto", "in", "notin",
        "subset", "subseteq", "to", "rightarrow", "Rightarrow", "leftarrow", "Leftrightarrow", "times", "pm",
        "leqslant", "geqslant", "ll", "gg", "lt", "gt",
    ]

    static let mathFunctions: Set<String> = [
        "log", "ln", "exp", "max", "min", "sin", "cos", "tan", "Pr", "det", "lim", "sup", "inf", "arg", "var",
        "Var", "Cov", "Corr", "E", "argmax", "argmin", "sgn",
    ]

    static let symbols: [String: String] = {
        var m: [String: String] = [
            "alpha": "α", "beta": "β", "gamma": "γ", "delta": "δ", "epsilon": "ϵ", "varepsilon": "ε",
            "zeta": "ζ", "eta": "η", "theta": "θ", "vartheta": "ϑ", "iota": "ι", "kappa": "κ", "lambda": "λ",
            "mu": "μ", "nu": "ν", "xi": "ξ", "pi": "π", "varpi": "ϖ", "rho": "ρ", "varrho": "ϱ", "sigma": "σ",
            "varsigma": "ς", "tau": "τ", "upsilon": "υ", "phi": "ϕ", "varphi": "φ", "chi": "χ", "psi": "ψ",
            "omega": "ω", "Gamma": "Γ", "Delta": "Δ", "Theta": "Θ", "Lambda": "Λ", "Xi": "Ξ", "Pi": "Π",
            "Sigma": "Σ", "Upsilon": "Υ", "Phi": "Φ", "Psi": "Ψ", "Omega": "Ω",
            "times": "×", "pm": "±", "mp": "∓", "cdot": "·", "cdots": "⋯", "ldots": "…", "dots": "…",
            "vdots": "⋮", "ddots": "⋱", "textellipsis": "…", "leq": "≤", "le": "≤", "geq": "≥", "ge": "≥",
            "leqslant": "⩽", "geqslant": "⩾", "neq": "≠", "ne": "≠", "approx": "≈", "sim": "∼", "simeq": "≃",
            "equiv": "≡", "propto": "∝", "infty": "∞", "partial": "∂", "nabla": "∇", "sum": "∑", "prod": "∏",
            "int": "∫", "in": "∈", "notin": "∉", "subset": "⊂", "subseteq": "⊆", "supset": "⊃", "cup": "∪",
            "cap": "∩", "forall": "∀", "exists": "∃", "to": "→", "rightarrow": "→", "leftarrow": "←",
            "Rightarrow": "⇒", "Leftarrow": "⇐", "Leftrightarrow": "⇔", "leftrightarrow": "↔", "mapsto": "↦",
            "uparrow": "↑", "downarrow": "↓", "ll": "≪", "gg": "≫", "ast": "∗", "star": "⋆", "dagger": "†",
            "dag": "†", "ddagger": "‡", "ddag": "‡", "circ": "∘", "bullet": "•", "prime": "′", "perp": "⊥",
            "mid": "|", "vert": "|", "lvert": "|", "rvert": "|", "Vert": "‖", "langle": "⟨", "rangle": "⟩",
            "lbrace": "{", "rbrace": "}", "lbrack": "[", "rbrack": "]", "lt": "&lt;", "gt": "&gt;",
            "neg": "¬", "lnot": "¬", "land": "∧", "lor": "∨", "wedge": "∧", "vee": "∨", "setminus": "∖",
            "emptyset": "∅", "varnothing": "∅", "hbar": "ℏ", "ell": "ℓ", "Re": "ℜ", "Im": "ℑ", "aleph": "ℵ",
            "checkmark": "✓", "cmark": "✓", "xmark": "✗", "tick": "✓", "S": "§", "P": "¶",
            "textdegree": "°", "degree": "°", "textperthousand": "‰", "textmu": "µ", "textbullet": "•",
            "textbar": "|", "textless": "&lt;", "textgreater": "&gt;", "textasciitilde": "~",
            "textasciicircum": "^", "textbackslash": "\\", "textunderscore": "_", "textdollar": "$",
            "textpm": "±", "texttimes": "×", "textminus": "−", "textdagger": "†", "textdaggerdbl": "‡",
            "textsection": "§", "textparagraph": "¶", "textasteriskcentered": "∗", "textquotedbl": "\"",
            "textquoteleft": "‘", "textquoteright": "’", "textquotedblleft": "“", "textquotedblright": "”",
            "textendash": "–", "textemdash": "—", "euro": "€", "texteuro": "€", "pounds": "£",
            "textsterling": "£", "yen": "¥", "copyright": "©", "textcopyright": "©", "textregistered": "®",
            "texttrademark": "™", "LaTeX": "LaTeX", "TeX": "TeX", "LaTeXe": "LaTeX2ε",
            "quad": "\u{2003}", "qquad": "\u{2003}\u{2003}", "enspace": "\u{2002}", "thinspace": "\u{2009}",
            "enskip": "\u{2002}", "nobreakspace": "&nbsp;", "space": " ", "newline": "<br>", "linebreak": "<br>",
            "ss": "ß", "ae": "æ", "AE": "Æ", "oe": "œ", "OE": "Œ", "o": "ø", "O": "Ø", "aa": "å", "AA": "Å",
            "l": "ł", "L": "Ł", "i": "ı", "j": "ȷ", "textbackslash ": "\\", "percent": "%",
        ]
        m["today"] = {
            let f = DateFormatter()
            f.dateStyle = .long
            return f.string(from: Date())
        }()
        return m
    }()

    static func doubleStruck(_ s: String) -> String {
        let map: [Character: String] = ["R": "ℝ", "N": "ℕ", "Z": "ℤ", "Q": "ℚ", "C": "ℂ", "E": "𝔼", "P": "ℙ", "1": "𝟙", "I": "𝕀", "V": "𝕍"]
        return s.map { map[$0] ?? String($0) }.joined()
    }

    static func formatNumber(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "{,}", with: ",")
        s = s.replacingOccurrences(of: "\\pm", with: " ± ")
        if let r = s.range(of: "[eE]", options: .regularExpression) {
            let mant = s[s.startIndex..<r.lowerBound]
            let exp = s[r.upperBound...]
            return (mant.isEmpty ? "" : mant + "\u{00D7}") + "10<sup>" + exp.replacingOccurrences(of: "-", with: "−") + "</sup>"
        }
        return s.replacingOccurrences(of: "-", with: "−")
    }

    static func unit(_ raw: String) -> String {
        let map: [String: String] = [
            "percent": "%", "metre": "m", "meter": "m", "kilo": "k", "milli": "m", "micro": "µ", "nano": "n",
            "gram": "g", "second": "s", "hour": "h", "minute": "min", "day": "d", "degreeCelsius": "°C",
            "celsius": "°C", "kelvin": "K", "litre": "L", "liter": "L", "squared": "²", "cubed": "³", "per": "/",
            "watt": "W", "joule": "J", "volt": "V", "hertz": "Hz", "mole": "mol", "degree": "°",
        ]
        var out = ""
        var sc = LatexScanner(raw)
        while !sc.atEnd {
            if sc.peek == "\\" {
                let n = sc.readCommand() ?? ""
                out += map[n] ?? n
            } else {
                let c = sc.peek!
                sc.i += 1
                if c == "^" { out += "<sup>" + (sc.readArg() ?? "") + "</sup>" } else if c == "." || c == "~" { out += "\u{2009}" } else { out.append(c) }
            }
        }
        return out
    }
}

extension LatexScanner {
    mutating func skipInlineSpacesAfterControlWord() {
        while i < s.count, s[i] == " " || s[i] == "\t" || s[i] == "\n" { i += 1 }
    }

    /// Like readBraced but does not skip leading whitespace (so `\foo {x}` style args are
    /// still read — TeX skips spaces — but text after a space-separated unknown command is not eaten).
    mutating func readBracedNoSpace() -> String? {
        guard peek == "{" else { return nil }
        return readBraced()
    }

    mutating func skipDimension() {
        skipSpaces()
        if peek == "\\" { _ = readCommand(); return }
        while let c = peek, c.isNumber || c == "." || c == "-" || c == "+" { i += 1 }
        skipSpaces()
        while let c = peek, c.isLetter { i += 1 }
    }

    /// After `\ifmmode`: returns (then, else) branches up to the matching \fi.
    mutating func readConditional() -> (String, String) {
        var depth = 1
        var thenPart = ""
        var elsePart = ""
        var inElse = false
        while !atEnd {
            if peek == "\\" {
                let start = i
                let name = readCommand() ?? ""
                if name.hasPrefix("if") { depth += 1 } else if name == "fi" {
                    depth -= 1
                    if depth == 0 { break }
                } else if name == "else" && depth == 1 {
                    inElse = true
                    continue
                }
                let tok = String(s[start..<i])
                if inElse { elsePart += tok } else { thenPart += tok }
                continue
            }
            if inElse { elsePart.append(s[i]) } else { thenPart.append(s[i]) }
            i += 1
        }
        return (thenPart, elsePart)
    }
}

enum Colors {
    static let named: [String: (Double, Double, Double)] = [
        "black": (0, 0, 0), "white": (1, 1, 1), "red": (1, 0, 0), "green": (0, 1, 0), "blue": (0, 0, 1),
        "cyan": (0, 1, 1), "magenta": (1, 0, 1), "yellow": (1, 1, 0), "gray": (0.5, 0.5, 0.5),
        "grey": (0.5, 0.5, 0.5), "lightgray": (0.75, 0.75, 0.75), "lightgrey": (0.75, 0.75, 0.75),
        "darkgray": (0.25, 0.25, 0.25), "orange": (1, 0.5, 0), "purple": (0.75, 0, 0.25), "brown": (0.75, 0.5, 0.25),
        "teal": (0, 0.5, 0.5), "olive": (0.5, 0.5, 0), "violet": (0.5, 0, 0.5), "pink": (1, 0.75, 0.75),
        "lime": (0.75, 1, 0),
    ]

    /// Converts xcolor syntax (`gray!20`, `red!50!blue`, `[HTML]{FF0000}`, `[rgb]{1,0,0}`) to CSS.
    static func css(_ spec: String, model: String? = nil) -> String {
        let spec = spec.trimmingCharacters(in: .whitespaces)
        if let model = model?.lowercased() {
            switch model {
            case "html": return "#" + spec
            case "rgb":
                let p = spec.split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
                if p.count == 3 { return rgb((p[0], p[1], p[2])) }
            case "rgb255", "RGB":
                let p = spec.split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
                if p.count == 3 { return rgb((p[0] / 255, p[1] / 255, p[2] / 255)) }
            case "gray":
                if let g = Double(spec) { return rgb((g, g, g)) }
            default: break
            }
            return "transparent"
        }
        let parts = spec.split(separator: "!").map { String($0) }
        guard let first = parts.first, var c = named[first] else { return "inherit" }
        var k = 1
        while k < parts.count {
            let pct = (Double(parts[k]) ?? 100) / 100
            let other = k + 1 < parts.count ? (named[parts[k + 1]] ?? (1, 1, 1)) : (1, 1, 1)
            c = (c.0 * pct + other.0 * (1 - pct), c.1 * pct + other.1 * (1 - pct), c.2 * pct + other.2 * (1 - pct))
            k += 2
        }
        return rgb(c)
    }

    static func rgb(_ c: (Double, Double, Double)) -> String {
        "rgb(\(Int(c.0 * 255)),\(Int(c.1 * 255)),\(Int(c.2 * 255)))"
    }
}
