import DaybookKit
import Foundation
import XCTest

/// Model output (summaries, action items, captions) may be prompt-injected: it never becomes a live
/// link in the app, and never a link or a fetched image in an export.
final class ModelTextTests: XCTestCase {
    private func links(_ text: AttributedString) -> [URL] { text.runs.compactMap { $0.link ?? $0.imageURL } }

    func testShownModelTextKeepsLinkTextButDropsTheLinks() {
        for source in ["Read [Open the deck](https://evil.example/login) first.",
                       "See [the file](file:///Users/me/Secrets.txt).",
                       "Tap [here](x-daybook-evil://do?thing=1).",
                       "Visit <https://evil.example/autolink>.",
                       "![a chart](https://evil.example/pixel.png?q=summary)"] {
            let shown = ModelText.inlineMarkdown(source)
            XCTAssertTrue(links(shown).isEmpty, source)
        }
        XCTAssertEqual(String(ModelText.inlineMarkdown("Read [Open the deck](https://evil.example/login) first.").characters),
                       "Read Open the deck first.")
    }

    func testShownModelTextKeepsEmphasis() {
        let shown = ModelText.inlineMarkdown("**Decide** by _Friday_ with `budget.xlsx`")
        XCTAssertEqual(String(shown.characters), "Decide by Friday with budget.xlsx")
        XCTAssertTrue(shown.runs.contains { $0.inlinePresentationIntent?.contains(.stronglyEmphasized) == true })
        XCTAssertTrue(shown.runs.contains { $0.inlinePresentationIntent?.contains(.code) == true })
    }

    private func render(_ markdown: String) throws -> AttributedString {
        try AttributedString(markdown: markdown, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))
    }

    /// Images, and links whose text isn't their own address, that a Markdown viewer would make. A bare
    /// URL is shown as itself (GFM autolinks it), so it hides nothing.
    private func hiddenLinks(_ markdown: String) throws -> [String] {
        let rendered = try render(markdown)
        return rendered.runs.compactMap { run in
            if let image = run.imageURL { return "image \(image)" }
            guard let link = run.link else { return nil }
            let text = String(rendered[run.range].characters)
            return text.hasPrefix("http") || text.hasPrefix("www") ? nil : "\(text) → \(link)"
        }
    }

    func testEscapedModelTextReadsTheSameAndLinksNowhere() throws {
        for source in ["![chart](//evil.example/pixel.png?q=revenue)",
                       "[Open the deck](javascript:alert(1))",
                       "<img src=x onerror=alert(1)>",
                       "[ref]: /evil",
                       "\\![escaped?](/evil)",
                       "Plain `code` and (parentheses) stay readable!"] {
            let escaped = ModelText.escapingMarkdown(source)
            let rendered = try render(escaped)
            XCTAssertTrue(links(rendered).isEmpty, escaped)
            XCTAssertEqual(String(rendered.characters), source, "a Markdown viewer shows the text as written")
        }
        for source in ["![](https://evil.example/?q=Q3-revenue-4.2M)", "[Open the deck](https://evil.example/login)",
                       "[x](file:///etc/hosts) and [y](x-evil://run)"] {
            XCTAssertFalse(try hiddenLinks(source).isEmpty, "unescaped, \(source) hides a link")
            XCTAssertEqual(try hiddenLinks(ModelText.escapingMarkdown(source)), [], source)
        }
        XCTAssertEqual(try hiddenLinks(ModelText.escapingMarkdown("<https://evil.example>")), [])
        XCTAssertEqual(ModelText.escapingMarkdown("**Bold** - item # 1"), "**Bold** - item # 1")
    }

    func testExportsEscapeModelTextButNotThePersonsNotes() {
        var meeting = Meeting(title: "Weekly [sync](https://evil.example/t)")
        meeting.notes = "My own [link](https://example.com/mine)"
        meeting.summary = MeetingSummary(
            overview: "Overview ![](https://evil.example/?q=secret)",
            sections: [.init(heading: "Plan <img src=x>", body: "- Ship [it](https://evil.example/s)")],
            actionItems: [ActionItem(text: "Call [Dana](tel:5551234)", owner: "Eve ![x](https://evil.example/o)")])
        meeting.unifiedTranscript = [TranscriptSegment(trackID: UUID(), start: 1, end: 2, text: "say ![](https://evil.example/a)")]

        for markdown in [MeetingExport.markdown(meeting), MeetingExport.summaryMarkdown(meeting)] {
            let modelPart = markdown.components(separatedBy: "## My notes")[0] + (markdown.components(separatedBy: "## Transcript").dropFirst().first ?? "")
            for line in modelPart.components(separatedBy: "\n") {
                XCTAssertEqual(try hiddenLinks(line), [], line)
            }
            XCTAssertTrue(markdown.contains("\\!\\[\\]\\(https://evil.example/?q=secret\\)"), markdown)
            XCTAssertTrue(markdown.contains("\\<img src=x\\>"), markdown)
        }
        let full = MeetingExport.markdown(meeting)
        XCTAssertTrue(full.contains("My own [link](https://example.com/mine)"), "the person's notes are theirs")
        XCTAssertTrue(full.contains("- Ship \\[it\\]"), "lists still work")
    }
}
