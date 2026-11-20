import CryptoKit
import Foundation
import PDFKit

public struct RenderSettings: Hashable, Codable, Sendable {
    public var engine: String = "pdflatex"
    public var extraPreamble: String = ""
    public var textWidth: String = "6.5in"

    public init() {}
}

public enum RenderOutcome: Sendable, Equatable {
    /// `errors` may be non-empty when TeX produced a PDF despite errors (nonstopmode).
    case success(pdf: URL, errors: [String], seconds: Double)
    case failure(errors: [String], log: String)
}

public struct RenderJob: Sendable {
    public var source: String
    public var fileURL: URL
    public var settings: RenderSettings

    public init(source: String, fileURL: URL, settings: RenderSettings) {
        self.source = source
        self.fileURL = fileURL
        self.settings = settings
    }

    /// Cache key: anything that can change the output.
    public var key: String {
        var h = SHA256()
        for part in [PDFRenderer.templateVersion, settings.engine, settings.extraPreamble, settings.textWidth,
                     fileURL.deletingLastPathComponent().path, source] {
            h.update(data: Data(part.utf8))
            h.update(data: Data([0]))
        }
        return h.finalize().map { String(format: "%02x", $0) }.joined().prefix(32).description
    }
}

/// Compiles .tex to PDF in the background with a content-addressed cache.
public actor PDFRenderer {
    public static let shared = PDFRenderer()
    static let templateVersion = "v4"

    public nonisolated let cacheDir: URL
    private var inFlight: [String: Task<RenderOutcome, Never>] = [:]
    private var prefetchQueue: [URL] = []
    private var prefetchSettings = RenderSettings()
    private var activePrefetch = 0
    private let maxPrefetch = 2

    public init() {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        cacheDir = base.appendingPathComponent("TablePeek", isDirectory: true)
        try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
    }

    // MARK: - Cache

    public nonisolated func pdfURL(forKey key: String) -> URL { cacheDir.appendingPathComponent("\(key).pdf") }
    nonisolated func errorsURL(forKey key: String) -> URL { cacheDir.appendingPathComponent("\(key).errors") }
    nonisolated func failedURL(forKey key: String) -> URL { cacheDir.appendingPathComponent("\(key).failed.log") }

    /// Synchronous cache check — cheap enough for the main thread (two stat calls).
    public nonisolated func cached(_ job: RenderJob) -> RenderOutcome? {
        let key = job.key
        let fm = FileManager.default
        let pdf = pdfURL(forKey: key)
        if fm.fileExists(atPath: pdf.path) {
            let errs = (try? String(contentsOf: errorsURL(forKey: key), encoding: .utf8))?
                .split(separator: "\n").map(String.init) ?? []
            return .success(pdf: pdf, errors: errs, seconds: 0)
        }
        if let log = try? String(contentsOf: failedURL(forKey: key), encoding: .utf8) {
            let errs = (try? String(contentsOf: errorsURL(forKey: key), encoding: .utf8))?
                .split(separator: "\n").map(String.init) ?? Self.extractErrors(log)
            return .failure(errors: errs, log: log)
        }
        return nil
    }

    public nonisolated func clearCache() {
        let fm = FileManager.default
        for f in (try? fm.contentsOfDirectory(at: cacheDir, includingPropertiesForKeys: nil)) ?? [] {
            try? fm.removeItem(at: f)
        }
    }

    public nonisolated func cacheSize() -> Int64 {
        let fm = FileManager.default
        var total: Int64 = 0
        for f in (try? fm.contentsOfDirectory(at: cacheDir, includingPropertiesForKeys: [.fileSizeKey])) ?? [] {
            total += Int64((try? f.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        return total
    }

    // MARK: - Rendering

    /// Renders now (high priority). Joins an in-flight render of the same content.
    public func render(_ job: RenderJob, force: Bool = false) async -> RenderOutcome {
        let key = job.key
        if force {
            for u in [pdfURL(forKey: key), errorsURL(forKey: key), failedURL(forKey: key)] {
                try? FileManager.default.removeItem(at: u)
            }
        } else {
            if let c = cached(job) { return c }
        }
        if let t = inFlight[key] { return await t.value }
        let t = Task.detached(priority: .userInitiated) { await Self.compile(job, key: key, cacheDir: self.cacheDir) }
        inFlight[key] = t
        let result = await t.value
        inFlight[key] = nil
        return result
    }

    /// Queue files to be rendered in the background so "full view" is instant later.
    public func prefetch(_ files: [URL], settings: RenderSettings) {
        prefetchSettings = settings
        let existing = Set(prefetchQueue)
        prefetchQueue += files.filter { !existing.contains($0) }
        pump()
    }

    public func cancelPrefetch() { prefetchQueue.removeAll() }

    private func pump() {
        while activePrefetch < maxPrefetch, !prefetchQueue.isEmpty {
            let url = prefetchQueue.removeFirst()
            guard let src = Self.readSource(url) else { continue }
            let job = RenderJob(source: src, fileURL: url, settings: prefetchSettings)
            if cached(job) != nil || inFlight[job.key] != nil { continue }
            activePrefetch += 1
            let key = job.key
            let t = Task.detached(priority: .utility) { await Self.compile(job, key: key, cacheDir: self.cacheDir) }
            inFlight[key] = t
            Task {
                _ = await t.value
                self.prefetchDone(key)
            }
        }
    }

    private func prefetchDone(_ key: String) {
        inFlight[key] = nil
        activePrefetch -= 1
        pump()
    }

    public static func readSource(_ url: URL) -> String? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1)
    }

    // MARK: - Compile

    static func compile(_ job: RenderJob, key: String, cacheDir: URL) async -> RenderOutcome {
        let t0 = Date()
        let fm = FileManager.default
        let build = cacheDir.appendingPathComponent("build-\(key)-\(UUID().uuidString.prefix(6))", isDirectory: true)
        try? fm.createDirectory(at: build, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: build) }

        let isFullDocument = job.source.contains("\\documentclass")
        let tex = isFullDocument ? job.source : wrapper(for: job.source, settings: job.settings)
        let main = build.appendingPathComponent("main.tex")
        do { try tex.write(to: main, atomically: true, encoding: .utf8) } catch {
            return .failure(errors: ["Could not write build file: \(error.localizedDescription)"], log: "")
        }

        guard let engine = findExecutable(job.settings.engine) else {
            return .failure(errors: ["Could not find `\(job.settings.engine)`. Is MacTeX installed (/Library/TeX/texbin)?"], log: "")
        }

        let passes = (job.source.contains("longtable") || job.source.contains("\\ref")) ? 2 : 1
        var status: Int32 = 0
        for _ in 0..<passes {
            status = await run(engine, args: ["-interaction=nonstopmode", "-file-line-error", "main.tex"], cwd: build,
                               texInputs: job.fileURL.deletingLastPathComponent().path)
        }
        let log = (try? String(contentsOf: build.appendingPathComponent("main.log"), encoding: .utf8))
            ?? (try? String(contentsOf: build.appendingPathComponent("main.log"), encoding: .isoLatin1)) ?? ""
        // Map wrapper line numbers back to the user's file.
        let lineOffset = isFullDocument ? 0 : (tex.components(separatedBy: "\\begin{document}\n").first?
            .components(separatedBy: "\n").count ?? 0)
        let errors = extractErrors(log, lineOffset: lineOffset)
        let outPDF = build.appendingPathComponent("main.pdf")
        let dest = cacheDir.appendingPathComponent("\(key).pdf")

        guard fm.fileExists(atPath: outPDF.path), let doc = PDFDocument(url: outPDF), doc.pageCount > 0 else {
            let msg = status == 15 ? ["Timed out after 60 s"] : (errors.isEmpty ? ["\(job.settings.engine) produced no PDF (exit \(status))"] : errors)
            try? log.write(to: cacheDir.appendingPathComponent("\(key).failed.log"), atomically: true, encoding: .utf8)
            try? msg.joined(separator: "\n").write(to: cacheDir.appendingPathComponent("\(key).errors"), atomically: true, encoding: .utf8)
            return .failure(errors: msg, log: log)
        }
        if !isFullDocument { cropToContent(doc) }
        if !doc.write(to: dest) { try? fm.copyItem(at: outPDF, to: dest) }
        if !errors.isEmpty {
            try? errors.joined(separator: "\n").write(to: cacheDir.appendingPathComponent("\(key).errors"), atomically: true, encoding: .utf8)
        }
        return .success(pdf: dest, errors: errors, seconds: Date().timeIntervalSince(t0))
    }

    /// Wraps a table fragment in a document that mimics a normal article page (so `\textwidth`,
    /// `\resizebox{\textwidth}` etc. behave as in a paper) but on a huge canvas; the result is
    /// cropped to the ink afterwards.
    static func wrapper(for source: String, settings: RenderSettings) -> String {
        """
        \\documentclass{article}
        \\usepackage[paperwidth=90cm,paperheight=200cm,left=2cm,top=2cm,textwidth=\(settings.textWidth),textheight=190cm]{geometry}
        \\pagestyle{empty}
        \\usepackage{iftex}
        \\ifPDFTeX\\usepackage[T1]{fontenc}\\usepackage[utf8]{inputenc}\\usepackage{lmodern}\\usepackage{textcomp}\\fi
        \\usepackage{amsmath,amssymb}
        \\usepackage{array,booktabs,multirow,makecell,tabularx,tabulary,longtable,threeparttable,dcolumn,graphicx,adjustbox,caption,siunitx,colortbl,hhline}
        \\usepackage[table]{xcolor}
        \\usepackage{pifont}
        \\usepackage[normalem]{ulem}
        \\IfFileExists{threeparttablex.sty}{\\usepackage{threeparttablex}}{}
        \\IfFileExists{tablefootnote.sty}{\\usepackage{tablefootnote}}{}
        \\providecommand{\\href}[2]{#2}
        \\providecommand{\\url}[1]{\\texttt{#1}}
        \\providecommand{\\hdashline}{\\hline}
        \\providecommand{\\cdashline}[1]{\\cline{#1}}
        \\providecommand{\\sym}[1]{\\ifmmode^{#1}\\else\\(^{#1}\\)\\fi}
        \\providecommand{\\cmark}{\\ding{51}}
        \\providecommand{\\xmark}{\\ding{55}}
        \\makeatletter
        % Floats become plain boxes so every table lands on the single big page.
        \\renewenvironment{table}[1][]{\\par\\medskip\\noindent\\begin{minipage}{\\textwidth}\\def\\@captype{table}}{\\end{minipage}\\par\\medskip}
        \\renewenvironment{table*}[1][]{\\par\\medskip\\noindent\\begin{minipage}{\\textwidth}\\def\\@captype{table}}{\\end{minipage}\\par\\medskip}
        \\newenvironment{sidewaystable}[1][]{\\begin{table}}{\\end{table}}
        \\newenvironment{sidewaystable*}[1][]{\\begin{table}}{\\end{table}}
        \\newenvironment{landscape}{}{}
        \\newenvironment{sideways}{}{}
        \\makeatother
        \(settings.extraPreamble)
        \\begin{document}
        \(source)
        \\end{document}
        """
    }

    static func extractErrors(_ log: String, lineOffset: Int = 0) -> [String] {
        func fix(_ n: Substring) -> String { Int(n).map { String(max(1, $0 - lineOffset)) } ?? String(n) }
        var errs: [String] = []
        let lines = log.components(separatedBy: "\n")
        for (i, line) in lines.enumerated() {
            let isFileLineError = line.range(of: #"^[^:\s]+\.tex:\d+: "#, options: .regularExpression) != nil
            if line.hasPrefix("! ") || isFileLineError {
                var msg: String
                if line.hasPrefix("! ") {
                    msg = String(line.dropFirst(2))
                } else if let m = line.firstMatch(of: #/^.*?main\.tex:(\d+): (.*)$/#) {
                    msg = "line \(fix(m.1)): \(m.2)"
                } else {
                    msg = line
                }
                // The following "l.<n> ..." line shows the offending source.
                if let ctx = lines[(i + 1)..<min(i + 6, lines.count)].first(where: { $0.hasPrefix("l.") }) {
                    var c = ctx.trimmingCharacters(in: .whitespaces)
                    if let m = c.firstMatch(of: #/^l\.(\d+)(.*)$/#) { c = "l.\(fix(m.1))\(m.2)" }
                    msg += " — " + c
                }
                if !errs.contains(msg) { errs.append(msg) }
                if errs.count >= 20 { break }
            }
        }
        return errs
    }

    // MARK: - Process

    static let searchPaths = ["/Library/TeX/texbin", "/opt/homebrew/bin", "/usr/local/bin", "/usr/texbin", "/usr/bin"]

    static func findExecutable(_ name: String) -> String? {
        if name.hasPrefix("/") { return FileManager.default.isExecutableFile(atPath: name) ? name : nil }
        let envPaths = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init)
        for dir in searchPaths + envPaths {
            let p = (dir as NSString).appendingPathComponent(name)
            if FileManager.default.isExecutableFile(atPath: p) { return p }
        }
        return nil
    }

    static func run(_ exe: String, args: [String], cwd: URL, texInputs: String, timeout: TimeInterval = 60) async -> Int32 {
        await withCheckedContinuation { cont in
            let p = Process()
            p.executableURL = URL(fileURLWithPath: exe)
            p.arguments = args
            p.currentDirectoryURL = cwd
            var env = ProcessInfo.processInfo.environment
            env["PATH"] = (searchPaths + [env["PATH"] ?? ""]).joined(separator: ":")
            // Trailing ":" keeps TeX's default search path.
            env["TEXINPUTS"] = ".:\(texInputs):"
            p.environment = env
            p.standardInput = FileHandle.nullDevice
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
            p.terminationHandler = { proc in cont.resume(returning: proc.terminationStatus) }
            do { try p.run() } catch {
                cont.resume(returning: -1)
                return
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                if p.isRunning { p.terminate() }
            }
        }
    }

    // MARK: - Cropping

    /// Crops each page to the bounding box of its non-white pixels (fast low-res raster scan).
    static func cropToContent(_ doc: PDFDocument, margin: CGFloat = 10) {
        for i in 0..<doc.pageCount {
            guard let page = doc.page(at: i), let cg = page.pageRef else { continue }
            let box = page.bounds(for: .mediaBox)
            let scale: CGFloat = 0.5  // 36 dpi is plenty to find the bbox
            let w = Int(box.width * scale), h = Int(box.height * scale)
            guard w > 0, h > 0,
                  let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                                      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)
            else { continue }
            ctx.setFillColor(gray: 1, alpha: 1)
            ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
            ctx.scaleBy(x: scale, y: scale)
            ctx.translateBy(x: -box.minX, y: -box.minY)
            ctx.drawPDFPage(cg)
            guard let data = ctx.data else { continue }
            let px = data.bindMemory(to: UInt8.self, capacity: w * h)
            var minX = w, minY = h, maxX = -1, maxY = -1
            for y in 0..<h {
                let row = px + y * w
                var x = 0
                while x < w {
                    if row[x] < 250 {
                        if x < minX { minX = x }
                        if x > maxX { maxX = x }
                        if y < minY { minY = y }
                        if y > maxY { maxY = y }
                    }
                    x += 1
                }
            }
            guard maxX >= 0 else { continue }
            // Bitmap rows run top->bottom in memory but CG's origin is bottom-left.
            let x0 = CGFloat(minX) / scale + box.minX - margin
            let x1 = CGFloat(maxX + 1) / scale + box.minX + margin
            let yTop = box.maxY - CGFloat(minY) / scale + margin
            let yBot = box.maxY - CGFloat(maxY + 1) / scale - margin
            let crop = CGRect(x: max(box.minX, x0), y: max(box.minY, yBot),
                              width: min(box.maxX, x1) - max(box.minX, x0), height: min(box.maxY, yTop) - max(box.minY, yBot))
            page.setBounds(crop, for: .mediaBox)
            page.setBounds(crop, for: .cropBox)
        }
    }
}
