//
//  AskAnswerBlocksTests.swift
//  YappyTests
//

import XCTest
@testable import Yappy

final class AskAnswerBlocksTests: XCTestCase {
    func testPlainTextIsOneParagraph() {
        let blocks = AskAnswerBlock.parse("Paris is the capital of France.")
        XCTAssertEqual(blocks, [.paragraph("Paris is the capital of France.")])
    }

    func testBlankLineSplitsParagraphs() {
        let blocks = AskAnswerBlock.parse("First.\n\nSecond.")
        XCTAssertEqual(blocks, [.paragraph("First."), .paragraph("Second.")])
    }

    func testPipeTableWithHeader() {
        let text = """
        Here you go:

        | City | Country |
        | --- | --- |
        | Paris | France |
        | Rome | Italy |
        """
        let blocks = AskAnswerBlock.parse(text)
        XCTAssertEqual(blocks.count, 2)
        XCTAssertEqual(blocks[0], .paragraph("Here you go:"))
        XCTAssertEqual(blocks[1], .table(
            header: ["City", "Country"],
            rows: [["Paris", "France"], ["Rome", "Italy"]]
        ))
    }

    func testAlignedSeparatorRowIsAccepted() {
        let text = "| a | b |\n|:---|---:|\n| 1 | 2 |"
        let blocks = AskAnswerBlock.parse(text)
        XCTAssertEqual(blocks, [.table(header: ["a", "b"], rows: [["1", "2"]])])
    }

    func testSingleStrayPipeLineStaysAParagraph() {
        let blocks = AskAnswerBlock.parse("|just a stray pipe line|")
        XCTAssertEqual(blocks, [.paragraph("|just a stray pipe line|")])
    }

    func testFencedCodeBlock() {
        let text = "Look:\n```swift\nlet x = 1\nprint(x)\n```\nDone."
        let blocks = AskAnswerBlock.parse(text)
        XCTAssertEqual(blocks, [
            .paragraph("Look:"),
            .code(language: "swift", text: "let x = 1\nprint(x)"),
            .paragraph("Done.")
        ])
    }

    func testUnterminatedFenceStillRendersAsCode() {
        // Mid-stream: the closing fence hasn't arrived yet.
        let blocks = AskAnswerBlock.parse("```\nhalf done")
        XCTAssertEqual(blocks, [.code(language: nil, text: "half done")])
    }

    func testBulletList() {
        let blocks = AskAnswerBlock.parse("- one\n- two\n- three")
        XCTAssertEqual(blocks, [.list(items: ["one", "two", "three"], ordered: false)])
    }

    func testNumberedList() {
        let blocks = AskAnswerBlock.parse("1. first\n2. second")
        XCTAssertEqual(blocks, [.list(items: ["first", "second"], ordered: true)])
    }

    func testImageLine() throws {
        let blocks = AskAnswerBlock.parse("![Eiffel Tower](https://example.com/eiffel.jpg)")
        XCTAssertEqual(blocks, [.image(alt: "Eiffel Tower", url: try XCTUnwrap(URL(string: "https://example.com/eiffel.jpg")))])
    }

    func testNonHTTPImageIsNotRendered() {
        let blocks = AskAnswerBlock.parse("![x](file:///etc/passwd)")
        XCTAssertEqual(blocks, [.paragraph("![x](file:///etc/passwd)")])
    }

    // MARK: - Headings

    func testHeadingParses() {
        let blocks = AskAnswerBlock.parse("## Current status\nAll good.")
        XCTAssertEqual(blocks, [
            .heading(level: 2, text: "Current status"),
            .paragraph("All good.")
        ])
    }

    func testHashWithoutSpaceIsNotAHeading() {
        let blocks = AskAnswerBlock.parse("#hashtag culture")
        XCTAssertEqual(blocks, [.paragraph("#hashtag culture")])
    }

    // MARK: - Narration-only detection (streaming suppression)

    func testNarrationOnlyDetected() {
        XCTAssertTrue(AskAnswerBlock.isNarrationOnly("Searching for the latest Starship launch schedule."))
        XCTAssertTrue(AskAnswerBlock.isNarrationOnly("Let me check that.\n"))
    }

    func testNarrationWithContentIsNotNarrationOnly() {
        XCTAssertFalse(AskAnswerBlock.isNarrationOnly("Searching for it.\nFound: July 6."))
        XCTAssertFalse(AskAnswerBlock.isNarrationOnly("The answer is July 6."))
    }

    // MARK: - Leading-narration strip

    func testStripsLeadingSearchNarration() {
        let text = "Searching for the US men's national team's next World Cup match.\nThe US plays next on Monday."
        XCTAssertEqual(AskAnswerBlock.strippingLeadingNarration(text), "The US plays next on Monday.")
    }

    func testStripsLetMeCheckWithBlankLine() {
        let text = "Let me check the latest specs.\n\nThe M4 has 10 CPU cores."
        XCTAssertEqual(AskAnswerBlock.strippingLeadingNarration(text), "The M4 has 10 CPU cores.")
    }

    func testKeepsNarrationOnlyAnswer() {
        // Never reduce an answer to nothing.
        let text = "Searching for that now."
        XCTAssertEqual(AskAnswerBlock.strippingLeadingNarration(text), text)
    }

    func testKeepsNormalFirstLine() {
        let text = "Paris is the capital of France.\nIt has been since 508 AD."
        XCTAssertEqual(AskAnswerBlock.strippingLeadingNarration(text), text)
    }

    func testKeepsMidTextNarrationLikeLines() {
        let text = "Here's the plan.\nSearching for flights is step one."
        XCTAssertEqual(AskAnswerBlock.strippingLeadingNarration(text), text)
    }

    func testLongFirstLineIsNotTreatedAsNarration() {
        let long = "Searching for the answer to this question requires understanding a lot of nuance, and here is that nuance explained in detail for you"
        let text = long + "\nMore."
        XCTAssertEqual(AskAnswerBlock.strippingLeadingNarration(text), text)
    }

    func testMixedAnswer() {
        let text = """
        The top options:

        | Model | Price |
        | --- | --- |
        | A | $10 |

        - fast
        - cheap

        That's it.
        """
        let blocks = AskAnswerBlock.parse(text)
        XCTAssertEqual(blocks.count, 4)
        XCTAssertEqual(blocks[0], .paragraph("The top options:"))
        XCTAssertEqual(blocks[1], .table(header: ["Model", "Price"], rows: [["A", "$10"]]))
        XCTAssertEqual(blocks[2], .list(items: ["fast", "cheap"], ordered: false))
        XCTAssertEqual(blocks[3], .paragraph("That's it."))
    }

    // MARK: - Plain text rendering

    func testPlainTextStripsBoldAndRendersLinksReadable() {
        XCTAssertEqual(
            AskAnswerBlock.plainText(from: "**x** [y](https://z)"),
            "x y (https://z)"
        )
    }

    func testPlainTextRendersTableAsTSV() {
        let text = """
        | City | Country |
        | --- | --- |
        | Paris | France |
        | Rome | Italy |
        """
        XCTAssertEqual(
            AskAnswerBlock.plainText(from: text),
            "City\tCountry\nParis\tFrance\nRome\tItaly"
        )
    }

    func testPlainTextRendersLists() {
        XCTAssertEqual(
            AskAnswerBlock.plainText(from: "- one\n- two\n\n1. first\n2. second"),
            "- one\n- two\n\n1. first\n2. second"
        )
    }

    func testPlainTextPassesCodeBlockThrough() {
        let text = "```swift\nlet x = 1\nprint(x)\n```"
        XCTAssertEqual(
            AskAnswerBlock.plainText(from: text),
            "let x = 1\nprint(x)"
        )
    }

    func testIdenticalParagraphsGetDistinctPositionalIDs() {
        let blocks = AskAnswerBlock.identified("Same.\n\nSame.")
        XCTAssertEqual(blocks.count, 2)
        XCTAssertNotEqual(blocks[0].id, blocks[1].id)
        XCTAssertEqual(blocks[0].id, "0:\(blocks[0].block.contentID)")
        XCTAssertEqual(blocks[1].id, "1:\(blocks[1].block.contentID)")
    }

    func testPlainTextJoinsBlocksWithBlankLines() {
        XCTAssertEqual(
            AskAnswerBlock.plainText(from: "# Title\n\nBody\n\n![Chart](https://example.com/chart.png)"),
            "Title\n\nBody\n\nChart"
        )
    }

    // MARK: - Speakable text rendering

    func testSpeakableTextSkipsCodeButReadsTablesAndKeepsSentencedParagraphsAndLists() {
        let text = """
        The top options

        ```swift
        let secret = "do not read"
        ```

        | Model | Price |
        | --- | --- |
        | A | $10 |

        - fast
        - cheap!
        """

        XCTAssertEqual(
            AskAnswerBlock.speakableText(from: text),
            "The top options.\nA: Price $10.\nfast.\ncheap!"
        )
    }

    func testSpeakableTextLinearizesTableRowsWithHeaderLabels() {
        let text = """
        | Chip | CPU cores | Memory |
        | --- | --- | --- |
        | Apple M4 | Up to 10 | 120 GB/s |
        | Apple M4 Pro | Up to 14 | 273 GB/s |
        """

        XCTAssertEqual(
            AskAnswerBlock.speakableText(from: text),
            "Apple M4: CPU cores Up to 10, Memory 120 GB/s.\nApple M4 Pro: CPU cores Up to 14, Memory 273 GB/s."
        )
    }

    func testSpeakableTextReadsHeaderlessTableCellsInOrder() {
        let text = """
        | a | b |
        | one | two |
        """

        // No `| --- |` separator, so the parser sees no header row: read cells in order.
        XCTAssertEqual(AskAnswerBlock.speakableText(from: text), "a, b.\none, two.")
    }

    func testSpeakableTextSpeaksLinkLabelAndDropsURL() {
        let spoken = AskAnswerBlock.speakableText(from: "According to [Reuters](https://r.com)")

        XCTAssertTrue(spoken.contains("Reuters"))
        XCTAssertFalse(spoken.contains("https://r.com"))
    }

    func testSpeakableTextReturnsEmptyForAllCodeAnswer() {
        let text = """
        ```swift
        let x = 1
        ```
        """

        XCTAssertEqual(AskAnswerBlock.speakableText(from: text), "")
    }

    func testSpeakableTextAddsPeriodWhenParagraphHasNoTerminalPunctuation() {
        XCTAssertEqual(AskAnswerBlock.speakableText(from: "No trailing punctuation"), "No trailing punctuation.")
    }

    // MARK: - Speakable text: source-citation stripping (speech only)

    func testSpeakableStripsTrailingSourceClauseKeepingTheSentence() {
        // The most common real pattern: "Source: …" tacked onto the last sentence.
        let text = "Bring layers, especially near the waterfront. Source: [SF Chronicle](https://sfchronicle.com/x)"
        XCTAssertEqual(AskAnswerBlock.speakableText(from: text), "Bring layers, especially near the waterfront.")
    }

    func testSpeakableDropsStandaloneSourceLine() {
        let text = "The match starts at 3 PM.\n\nSource: [The Guardian](https://theguardian.com/x)"
        XCTAssertEqual(AskAnswerBlock.speakableText(from: text), "The match starts at 3 PM.")
    }

    func testSpeakableDropsPlainTextSourceLine() {
        let text = "Apple announced it today.\n\nSource: Apple Newsroom."
        XCTAssertEqual(AskAnswerBlock.speakableText(from: text), "Apple announced it today.")
    }

    func testSpeakableStripsSourceWithTrailingParenthetical() {
        let text = "Mars is about 140 million miles away. Source: [Space.com](https://space.com/x) (citing NASA)"
        XCTAssertEqual(AskAnswerBlock.speakableText(from: text), "Mars is about 140 million miles away.")
    }

    func testSpeakableStripsInlineSourceParenthetical() {
        let text = "The M4 has up to 10 CPU cores (source: Apple)."
        XCTAssertEqual(AskAnswerBlock.speakableText(from: text), "The M4 has up to 10 CPU cores.")
    }

    func testSpeakableStripsCitingParenthetical() {
        let text = "The distance is 140 million miles (citing NASA)."
        XCTAssertEqual(AskAnswerBlock.speakableText(from: text), "The distance is 140 million miles.")
    }

    func testSpeakableStripsNumericFootnoteMarkers() {
        let text = "The launch is Monday [1] with a backup Tuesday [2]."
        XCTAssertEqual(AskAnswerBlock.speakableText(from: text), "The launch is Monday with a backup Tuesday.")
    }

    func testSpeakableKeepsWordSourceInOrdinaryProse() {
        // No colon, not a citation — must be untouched.
        let text = "The source of the Nile is Lake Victoria."
        XCTAssertEqual(AskAnswerBlock.speakableText(from: text), "The source of the Nile is Lake Victoria.")
    }

    func testSpeakableKeepsNaturalSourceMentionWovenIntoSentence() {
        // A source named as prose is grammatically essential — dropping it would
        // break the sentence, so it stays.
        let text = "According to Reuters, the launch is Monday."
        XCTAssertEqual(AskAnswerBlock.speakableText(from: text), "According to Reuters, the launch is Monday.")
    }

    func testSpeakableStripsBoldSourceClause() {
        let text = "The eclipse is August 12, 2026. **Source:** [NASA](https://nasa.gov/x)"
        XCTAssertEqual(AskAnswerBlock.speakableText(from: text), "The eclipse is August 12, 2026.")
    }

    func testSpeakableDropsTrailingSourcesHeadingSection() {
        let text = """
        The top three are A, B, and C.

        ## Sources
        - [One](https://one.com)
        - [Two](https://two.com)
        """
        XCTAssertEqual(AskAnswerBlock.speakableText(from: text), "The top three are A, B, and C.")
    }

    func testPlainTextInsertionKeepsSources() {
        // Citations are stripped for SPEECH only; pasted/inserted text keeps them.
        let text = "The match starts at 3 PM. Source: [The Guardian](https://theguardian.com/x)"
        XCTAssertTrue(AskAnswerBlock.plainText(from: text).contains("Guardian"))
    }

    func testHTTPImageIsNotParsedAsImage() {
        let blocks = AskAnswerBlock.parse("![alt](http://insecure.example/x.png)")
        XCTAssertFalse(blocks.contains { block in
            if case .image = block { return true } else { return false }
        })
    }

}
