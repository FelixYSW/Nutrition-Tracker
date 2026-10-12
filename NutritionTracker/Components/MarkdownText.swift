import SwiftUI

/// Renders the Markdown an LLM replies with - bold, italics, code, links,
/// headings, bullet and numbered lists - instead of showing the raw symbols.
///
/// SwiftUI's `Text` only formats Markdown in string literals, and
/// `AttributedString(markdown:)` with full syntax drops line breaks between
/// paragraphs and list items when displayed. So the text is split into lines
/// here, each line's block type (heading, bullet, number, paragraph) is laid
/// out explicitly, and only the inline styling is left to Foundation.
struct MarkdownText: View {
    let source: String

    init(_ source: String) {
        self.source = source
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(Self.blocks(from: source).enumerated()), id: \.offset) { _, block in
                view(for: block)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func view(for block: Block) -> some View {
        switch block {
        case .heading(let text):
            Text(Self.inline(text))
                .fontWeight(.semibold)
                .padding(.top, 2)
        case .bullet(let text, let level):
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(level == 0 ? "\u{2022}" : "\u{25E6}")
                    .foregroundStyle(.secondary)
                Text(Self.inline(text))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.leading, CGFloat(level) * 14)
        case .numbered(let marker, let text):
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(marker)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                Text(Self.inline(text))
                    .fixedSize(horizontal: false, vertical: true)
            }
        case .paragraph(let text):
            Text(Self.inline(text))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Parsing

    enum Block: Equatable {
        case heading(String)
        case bullet(String, level: Int)
        case numbered(marker: String, text: String)
        case paragraph(String)
    }

    /// Splits the reply into display blocks. Blank lines just separate blocks;
    /// consecutive plain lines stay separate lines, as the model wrote them.
    static func blocks(from source: String) -> [Block] {
        source.components(separatedBy: .newlines).compactMap { rawLine in
            let indent = rawLine.prefix { $0 == " " || $0 == "\t" }.count
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, line != "---", line != "***" else { return nil }

            if line.hasPrefix("#") {
                let text = line.drop { $0 == "#" }.trimmingCharacters(in: .whitespaces)
                return text.isEmpty ? nil : .heading(text)
            }
            for marker in ["- ", "* ", "\u{2022} ", "+ "] where line.hasPrefix(marker) {
                return .bullet(String(line.dropFirst(marker.count)), level: indent >= 2 ? 1 : 0)
            }
            // "1. item" or "1) item"
            let digits = line.prefix { $0.isNumber }
            if !digits.isEmpty, digits.count <= 3 {
                let rest = line.dropFirst(digits.count)
                if rest.hasPrefix(". ") || rest.hasPrefix(") ") {
                    return .numbered(marker: "\(digits).", text: String(rest.dropFirst(2)))
                }
            }
            return .paragraph(line)
        }
    }

    /// Bold, italics, inline code and links within one line. Falls back to the
    /// plain text if the line isn't valid Markdown, so nothing is ever lost.
    static func inline(_ text: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .inlineOnlyPreservingWhitespace,
            failurePolicy: .returnPartiallyParsedIfPossible)
        return (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
    }
}

#Preview {
    MarkdownText("""
    **Best fit:** 2 sticks of satay and a *small* bowl of fried rice.

    ## Why
    - About **450 kcal**, 25 g protein
    - Leaves ~200 kcal for dinner
    1. Order the satay
    2. Share the rice
    """)
    .padding()
}
