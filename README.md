# TablePeek

A small macOS app for previewing LaTeX tables stored as `.tex` files, with no manual compile step.

- **Quick view** (instant, about 5 ms): a best-effort parser turns `tabular`-style environments into HTML, typeset in Latin Modern. It handles booktabs rules (`\toprule`, `\cmidrule(lr){2-3}`, …), `\hline`/`\cline`, vertical rules, `\multicolumn`, `\multirow`, `\makecell`/`\shortstack`, `\sym{}` (esttab), inline math, colors, captions, `threeparttable` notes, simple user macros, nested tabulars, and longtable heads and feet.
- **PDF view** (the real output): the file is compiled with `pdflatex`/`xelatex`/`lualatex` in the background as soon as you select it. Fragments are wrapped in an article-like page (6.5in `\textwidth`, common table packages preloaded) and cropped to the ink. Files that contain `\documentclass` are compiled as they are.
- **Cache**: PDFs are stored by content hash in `~/Library/Caches/TablePeek`, so a table you've already seen opens instantly. When you open a folder, its 60 most recently modified files are pre-rendered in the background (2 at a time).
- **Live reload**: the opened folder is watched with FSEvents. If a script rewrites a table, both views update automatically, and new files appear in the sidebar.
- **Source view** shows the raw LaTeX.

If you select PDF mode while a PDF is still compiling, you see the quick view with a "Compiling…" badge, and it switches over when the PDF is ready. LaTeX errors show as a banner (nonstopmode still produces a PDF) or as a failure page with the log. Line numbers refer to your file.

## Requirements

- macOS 14+
- Swift toolchain (Command Line Tools are enough; Xcode is not needed)
- A TeX distribution (MacTeX). The app looks in `/Library/TeX/texbin`, `/opt/homebrew/bin`, `/usr/local/bin`.

## Build & install

```bash
./scripts/build-app.sh            # -> build/TablePeek.app
./scripts/build-app.sh --install  # also copies to ~/Applications
```

During development: `swift run TablePeek path/to/folder-or-file.tex`.

## Usage

- Open a folder or `.tex` file with **⌘O**, drag it onto the window, or `open -a TablePeek table.tex`. The app also registers as an alternate "Open With" handler for `.tex`.
- Opening a single file browses its folder, so you can arrow through sibling tables.
- The last folder is restored on launch.

| Shortcut | Action |
|---|---|
| ⌘1 / ⌘2 / ⌘3 | Quick / PDF / Source |
| ⇧⌘T | Toggle Quick ↔ PDF |
| ↑ ↓ (sidebar) or ⌘↑ / ⌘↓ | Previous / next file |
| ⌘R | Force recompile (bypasses the cache) |
| ⌘+ / ⌘− / ⌘0 | Zoom (both views; pinch also works) |
| ⌘E | Open in editor (configurable in Settings) |
| ⇧⌘P | Open the compiled PDF in Preview |
| ⇧⌘R | Reveal in Finder |

The sidebar can be sorted by name or by **recently modified**, which is handy when a script has just regenerated outputs.

**Settings (⌘,)**: TeX engine, `\textwidth` for fragments, extra preamble for project macros and packages (e.g. `\newcommand{\sym}…`, `\usepackage{…}`), the pre-render toggle, the editor app, and clearing the cache.

## CLI

`build/TablePeek.app/Contents/MacOS/tablepeek-cli` exposes the same pipeline:

```bash
tablepeek-cli table.tex out.html     # quick parser -> standalone HTML
tablepeek-cli --pdf table.tex        # compile (cached) and print the PDF path + errors
```

## Layout

```
Sources/TablePeekCore/   parser (LatexScanner, InlineConverter, TableParser), HTMLRenderer, PDFRenderer (compile/cache/crop)
Sources/TablePeek/       SwiftUI app (AppModel, views, FSEvents watcher)
Sources/tablepeek-cli/   command-line front end
Examples/                sample tables
scripts/                 build-app.sh, make-icon.swift
```

## Limitations

- The quick parser is regex/scanner based. It approximates layout: no decimal alignment for `S`/`D` columns, no `tabularray` (`tblr`) syntax, and macros with complex arguments are dropped and their last argument kept.
- `\input` paths and graphics resolve relative to the table's own folder.
- No Finder Quick Look (spacebar) extension, since that needs Xcode to build an app extension.
