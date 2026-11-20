import Foundation
import TablePeekCore

// Usage:
//   tablepeek-cli file.tex [out.html]   quick-parse tables to a standalone HTML page
//   tablepeek-cli --pdf file.tex        compile with the app's PDF pipeline, print the cached PDF path
let args = Array(CommandLine.arguments.dropFirst())
guard let first = args.first else {
    FileHandle.standardError.write("usage: tablepeek-cli [--pdf] file.tex [out.html]\n".data(using: .utf8)!)
    exit(2)
}

if first == "--pdf", args.count >= 2 {
    let url = URL(fileURLWithPath: args[1]).standardizedFileURL
    guard let src = PDFRenderer.readSource(url) else { print("cannot read \(url.path)"); exit(1) }
    let job = RenderJob(source: src, fileURL: url, settings: RenderSettings())
    let sem = DispatchSemaphore(value: 0)
    Task {
        let r = await PDFRenderer.shared.render(job, force: args.contains("--force"))
        switch r {
        case let .success(pdf, errors, secs):
            print("OK \(String(format: "%.2f", secs))s \(pdf.path)")
            errors.forEach { print("  ! \($0)") }
        case let .failure(errors, _):
            print("FAILED")
            errors.forEach { print("  ! \($0)") }
        }
        sem.signal()
    }
    sem.wait()
    exit(0)
}

let src = PDFRenderer.readSource(URL(fileURLWithPath: first)) ?? ""
let result = TableParser.parse(src)
let html = HTMLRenderer.page(body: HTMLRenderer.bodyHTML(result))
if args.count >= 2 {
    try html.write(toFile: args[1], atomically: true, encoding: .utf8)
    print("\(result.tables.count) table(s), parsed in \(String(format: "%.1f", result.elapsed * 1000)) ms -> \(args[1])")
} else {
    print(html)
}
