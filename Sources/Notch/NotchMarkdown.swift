import Foundation

/// The blocks of an agent's Markdown reply, enough to draw it like T3 Code does: headings, paragraphs, list items,
/// tables and code. Inline styling (bold, code, links) stays in the text for `AttributedString` to read. Foundation
/// only, so the checks compile it without the app.
enum NotchMarkdownBlock: Equatable, Sendable {
    case heading(String)
    case paragraph(String)
    /// A list item with its marker: "•" for a bullet, "3." for a numbered item.
    case item(marker: String, text: String)
    /// Rows of cells; the first row is the header.
    case table([[String]])
    case code(String)

    static func parse(_ markdown: String) -> [NotchMarkdownBlock] {
        var blocks: [NotchMarkdownBlock] = []
        var paragraph: [String] = []
        var table: [[String]] = []
        /// Whether the current table's header separator has gone by; later rows of dashes are content.
        var separated = false
        var code: [String]?

        func flush() {
            if !paragraph.isEmpty { blocks.append(.paragraph(paragraph.joined(separator: " "))); paragraph = [] }
            if !table.isEmpty { blocks.append(.table(table)); table = [] }
            separated = false
        }

        // Character checks first, so most lines never reach a Regex; parsing runs off the main thread anyway.
        for raw in markdown.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("```") || line.hasPrefix("~~~") {
                if let lines = code {
                    blocks.append(.code(lines.joined(separator: "\n")))
                    code = nil
                } else {
                    flush()
                    code = []
                }
                continue
            }
            if code != nil { code?.append(raw); continue }
            if line.hasPrefix("|") {
                if !paragraph.isEmpty { flush() }
                // The |---|:--:| line under the header only marks it; a row of dashes further down is content.
                if table.count == 1, !separated, line.allSatisfy({ "|-: ".contains($0) }) { separated = true; continue }
                // An escaped \| is a pipe inside a cell.
                let cells = line.replacingOccurrences(of: "\\|", with: "\u{1}").trimmingCharacters(in: CharacterSet(charactersIn: "|"))
                table.append(cells.components(separatedBy: "|")
                    .map { $0.replacingOccurrences(of: "\u{1}", with: "|").trimmingCharacters(in: .whitespaces) })
                continue
            }
            // An image on its own line moves to the strip under the reply when it is a local file; a web or relative
            // image stays in the text as a link to it.
            if line.hasPrefix("!["), let image = line.wholeMatch(of: NotchAgentImage.pattern) {
                flush()
                let target = String(image.angled ?? image.plain ?? "")
                if NotchAgentImage.path(of: target) == nil {
                    blocks.append(.paragraph("[\(image.alt.isEmpty ? target : String(image.alt))](\(target))"))
                }
                continue
            }
            let bare = line.filter { $0 != " " }
            if line.isEmpty || bare.count >= 3 && (bare.allSatisfy { $0 == "-" } || bare.allSatisfy { $0 == "*" }
                                                    || bare.allSatisfy { $0 == "_" }) {
                flush()
                continue
            }
            if line.first == "#", let heading = line.firstMatch(of: #/^#{1,6}\s+(.+)$/#) {
                flush()
                blocks.append(.heading(String(heading.1)))
                continue
            }
            if let first = line.first, "-*+".contains(first), let bullet = line.firstMatch(of: #/^[-*+]\s+(.+)$/#) {
                flush()
                blocks.append(.item(marker: "•", text: String(bullet.1)))
                continue
            }
            if line.first?.isNumber == true, let numbered = line.firstMatch(of: #/^(\d+)[.)]\s+(.+)$/#) {
                flush()
                blocks.append(.item(marker: "\(numbered.1).", text: String(numbered.2)))
                continue
            }
            // An indented line under a list item continues it.
            if raw.hasPrefix("  ") || raw.hasPrefix("\t"), paragraph.isEmpty, table.isEmpty,
               case .item(let marker, let text) = blocks.last {
                blocks[blocks.count - 1] = .item(marker: marker, text: text + " " + line)
                continue
            }
            if !table.isEmpty { flush() }
            paragraph.append(line)
        }
        if let lines = code { blocks.append(.code(lines.joined(separator: "\n"))) }
        flush()
        return blocks
    }
}
