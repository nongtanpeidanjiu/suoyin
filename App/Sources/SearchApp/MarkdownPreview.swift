import Foundation

/// Turns Markdown into a small, self-contained HTML page for Quick Look,
/// using only the system's Markdown parser. Every piece of the document's
/// text is escaped; no link, image, script or remote resource is emitted, so
/// the page shows the file and nothing else. Returns nil whenever the parser
/// gives up, and the caller then shows the file as plain text.
enum MarkdownPreview {
    static func html(from markdown: String, title: String) -> String? {
        // YAML front matter is not Markdown; show it as it is, in a box.
        var markdown = markdown
        var frontMatter = ""
        if let (yaml, rest) = splitFrontMatter(markdown) {
            frontMatter = "<pre class=\"front\"><code>\(escape(yaml))</code></pre>\n"
            markdown = rest
        }
        let options = AttributedString.MarkdownParsingOptions(
            allowsExtendedAttributes: false, interpretedSyntax: .full,
            failurePolicy: .returnPartiallyParsedIfPossible)
        guard let document = try? AttributedString(markdown: markdown, options: options) else { return nil }
        // The parser drops nothing silently in a well-formed run list, but a
        // document whose text all but vanished is shown raw instead.
        let parsed = document.characters.count
        let visible = markdown.unicodeScalars.filter { !CharacterSet.whitespacesAndNewlines.contains($0) }.count
        if visible > 200, parsed * 3 < visible { return nil }

        var writer = Writer()
        for run in document.runs {
            let text = String(document[run.range].characters)
            let blocks = (run.presentationIntent?.components ?? []).reversed()
            writer.enter(Array(blocks))
            writer.inline(text, run.inlinePresentationIntent ?? [])
        }
        writer.finish()
        return page(body: frontMatter + writer.out, title: title)
    }

    /// Splits off a leading `---` … `---` (or `...`) block.
    private static func splitFrontMatter(_ text: String) -> (String, String)? {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        guard lines.count > 2, lines[0].trimmingCharacters(in: .whitespaces) == "---" else { return nil }
        for index in 1..<min(lines.count, 200) {
            let line = lines[index].trimmingCharacters(in: .whitespaces)
            if line == "---" || line == "..." {
                return (lines[1..<index].joined(separator: "\n"), lines[(index + 1)...].joined(separator: "\n"))
            }
        }
        return nil
    }

    private struct Writer {
        var out = ""
        /// Blocks currently open, outermost first.
        private var open: [PresentationIntent.IntentType] = []
        /// The column the next cell of the open table row should have.
        private var nextColumn = 0
        private var alignments: [String] = []
        /// Text outside any block (raw HTML, which is shown as text).
        private var loose = false
        private var inCode = false

        mutating func enter(_ blocks: [PresentationIntent.IntentType]) {
            if loose, !blocks.isEmpty { out += "</p>\n"; loose = false }
            var shared = 0
            while shared < min(open.count, blocks.count), open[shared].identity == blocks[shared].identity { shared += 1 }
            while open.count > shared { close(open.removeLast()) }
            for block in blocks[shared...] {
                start(block)
                open.append(block)
            }
        }

        mutating func finish() {
            enter([])
            if loose { out += "</p>\n"; loose = false }
        }

        mutating func inline(_ text: String, _ style: InlinePresentationIntent) {
            if inCode { out += escape(text); return }
            // A rule's run is a placeholder character, not document text.
            if case .thematicBreak? = open.last?.kind { return }
            if open.isEmpty, !loose { out += "<p class=\"raw\">"; loose = true }
            var html = escape(text).replacingOccurrences(of: "\u{2028}", with: "<br>")
                .replacingOccurrences(of: "\n", with: "<br>")
            if style.contains(.code) { html = "<code>\(html)</code>" }
            if style.contains(.strikethrough) { html = "<del>\(html)</del>" }
            if style.contains(.emphasized) { html = "<em>\(html)</em>" }
            if style.contains(.stronglyEmphasized) { html = "<strong>\(html)</strong>" }
            out += html
        }

        private mutating func start(_ block: PresentationIntent.IntentType) {
            switch block.kind {
            case .paragraph: out += "<p>"
            case .header(let level): out += "<h\(min(max(level, 1), 6))>"
            case .orderedList: out += "<ol>"
            case .unorderedList: out += "<ul>"
            case .listItem(let ordinal):
                // An ordered item carries its own number (a list may start at 3).
                out += isOrderedItem ? "<li value=\"\(ordinal)\">" : "<li>"
            case .codeBlock: out += "<pre><code>"; inCode = true
            case .blockQuote: out += "<blockquote>"
            case .thematicBreak: out += "<hr>"
            case .table(let columns):
                alignments = columns.map {
                    switch $0.alignment {
                    case .center: return " style=\"text-align:center\""
                    case .right: return " style=\"text-align:right\""
                    default: return ""
                    }
                }
                out += "<table>"
            case .tableHeaderRow: out += "<thead><tr>"; nextColumn = 0
            case .tableRow: out += "<tr>"; nextColumn = 0
            case .tableCell(let column):
                // An empty cell has no text and so no run: fill the gap.
                while nextColumn < column { out += cellTag(nextColumn) + "</\(cellName)>"; nextColumn += 1 }
                out += cellTag(column)
                nextColumn = column + 1
            @unknown default: out += "<div>"
            }
        }

        private mutating func close(_ block: PresentationIntent.IntentType) {
            switch block.kind {
            case .paragraph: out += "</p>\n"
            case .header(let level): out += "</h\(min(max(level, 1), 6))>\n"
            case .orderedList: out += "</ol>\n"
            case .unorderedList: out += "</ul>\n"
            case .listItem: out += "</li>\n"
            case .codeBlock: out += "</code></pre>\n"; inCode = false
            case .blockQuote: out += "</blockquote>\n"
            case .thematicBreak: break
            case .table: out += "</table>\n"
            case .tableHeaderRow: padRow(); out += "</tr></thead>\n"
            case .tableRow: padRow(); out += "</tr>\n"
            case .tableCell: out += "</\(cellName)>"
            @unknown default: out += "</div>"
            }
        }

        private mutating func padRow() {
            while nextColumn < alignments.count { out += cellTag(nextColumn) + "</\(cellName)>"; nextColumn += 1 }
        }

        private var isOrderedItem: Bool {
            if case .orderedList = open.last?.kind { return true }
            return false
        }

        private var inHeaderRow: Bool {
            open.contains { if case .tableHeaderRow = $0.kind { return true } else { return false } }
        }

        private var cellName: String { inHeaderRow ? "th" : "td" }
        private func cellTag(_ column: Int) -> String {
            "<\(cellName)\(alignments.indices.contains(column) ? alignments[column] : "")>"
        }
    }

    static func escape(_ text: String) -> String {
        var result = ""
        result.reserveCapacity(text.utf8.count)
        for character in text {
            switch character {
            case "&": result += "&amp;"
            case "<": result += "&lt;"
            case ">": result += "&gt;"
            case "\"": result += "&quot;"
            default: result.append(character)
            }
        }
        return result
    }

    private static func page(body: String, title: String) -> String {
        """
        <!DOCTYPE html>
        <html lang="zh-CN"><head><meta charset="utf-8">
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; style-src 'unsafe-inline'">
        <title>\(escape(title))</title>
        <style>
        :root { color-scheme: light dark; }
        body { font: 14px/1.6 -apple-system, "PingFang SC", sans-serif; margin: 20px 24px 40px;
               color: #1d1d1f; background: #fff; word-wrap: break-word; }
        h1, h2, h3, h4, h5, h6 { line-height: 1.3; margin: 1.2em 0 0.5em; }
        h1 { font-size: 1.8em; border-bottom: 1px solid #d2d2d7; padding-bottom: 0.25em; }
        h2 { font-size: 1.45em; border-bottom: 1px solid #e5e5ea; padding-bottom: 0.2em; }
        h3 { font-size: 1.2em; } h4, h5, h6 { font-size: 1em; }
        p, ul, ol, pre, blockquote, table { margin: 0 0 0.9em; }
        ul, ol { padding-left: 1.6em; } li > p { margin: 0.2em 0; }
        code { font: 12.5px/1.5 ui-monospace, Menlo, monospace; background: rgba(127,127,127,0.14);
               padding: 0.1em 0.3em; border-radius: 4px; }
        pre { background: rgba(127,127,127,0.11); padding: 10px 12px; border-radius: 6px;
              overflow-x: auto; white-space: pre; }
        pre code { background: none; padding: 0; }
        blockquote { margin-left: 0; padding: 0 1em; color: #6e6e73; border-left: 3px solid #d2d2d7; }
        table { border-collapse: collapse; display: block; overflow-x: auto; }
        th, td { border: 1px solid #d2d2d7; padding: 4px 10px; text-align: left; vertical-align: top; }
        th { background: rgba(127,127,127,0.10); }
        pre.front { color: #6e6e73; }
        p.raw { font: 12.5px/1.5 ui-monospace, Menlo, monospace; color: #6e6e73; }
        hr { border: none; border-top: 1px solid #d2d2d7; margin: 1.4em 0; }
        @media (prefers-color-scheme: dark) {
          body { color: #f5f5f7; background: #1e1e1e; }
          h1, h2, th, td, hr, blockquote { border-color: #48484a; }
          blockquote { color: #a1a1a6; }
        }
        </style></head><body>
        \(body)
        </body></html>
        """
    }
}
