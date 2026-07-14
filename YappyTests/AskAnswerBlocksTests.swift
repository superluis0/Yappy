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
            "Apple M4: CPU cores Up to 10 and Memory 120 GB/s.\nApple M4 Pro: CPU cores Up to 14 and Memory 273 GB/s."
        )
    }

    func testSpeakableTableRowUsesOxfordJoinForThreeOrMoreValues() {
        let text = """
        | Day | High | Low | Sky |
        | --- | --- | --- | --- |
        | Monday | 98 | 74 | Sunny |
        """

        XCTAssertEqual(
            AskAnswerBlock.speakableText(from: text),
            "Monday: High 98, Low 74, and Sky Sunny."
        )
    }

    func testSpeakableTextCapsLongTablesWithARowCountTrailer() {
        let rows = (1...10).map { "| Item \($0) | \($0) |" }.joined(separator: "\n")
        let text = "| Name | Count |\n| --- | --- |\n" + rows

        let spoken = AskAnswerBlock.speakableText(from: text)
        XCTAssertTrue(spoken.contains("Item 6: Count 6."))
        XCTAssertFalse(spoken.contains("Item 7"), "rows past the cap are not recited")
        XCTAssertTrue(spoken.hasSuffix("Plus 4 more rows in the table."))
    }

    func testSpeakableTextReadsSevenRowTableInFullWithoutSillyTrailer() {
        let rows = (1...7).map { "| Item \($0) | \($0) |" }.joined(separator: "\n")
        let text = "| Name | Count |\n| --- | --- |\n" + rows

        let spoken = AskAnswerBlock.speakableText(from: text)
        XCTAssertTrue(spoken.contains("Item 7: Count 7."))
        XCTAssertFalse(spoken.contains("more rows"))
    }

    func testSpeakableTextReadsHeaderlessTableCellsInOrder() {
        let text = """
        | a | b |
        | one | two |
        """

        // No `| --- |` separator, so the parser sees no header row: read cells
        // in order with the natural two-item join.
        XCTAssertEqual(AskAnswerBlock.speakableText(from: text), "a and b.\none and two.")
    }

    func testSpeakableTextSpeaksLinkLabelAndDropsURL() {
        let spoken = AskAnswerBlock.speakableText(from: "According to [Reuters](https://r.com)")

        XCTAssertTrue(spoken.contains("Reuters"))
        XCTAssertFalse(spoken.contains("https://r.com"))
    }

    func testSpeakableTextAnnouncesAllCodeAnswer() {
        let text = """
        ```swift
        let x = 1
        ```
        """

        // Dead air was worse than a pointer to the screen.
        XCTAssertEqual(
            AskAnswerBlock.speakableText(from: text),
            "The answer is a code block on screen."
        )
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

    func testSpeakableStripsGrokLinkClusterParenthetical() {
        // Grok 4.5 cites as a parenthetical group of bare markdown links (no "Source:"/"citing").
        let text = "Chiropractic was founded in 1895. ([Wikipedia](https://en.wikipedia.org/wiki/Chiropractic); [Palmer College](https://www.palmer.edu))"
        XCTAssertEqual(AskAnswerBlock.speakableText(from: text), "Chiropractic was founded in 1895.")
    }

    func testSpeakableStripsGrokSingleLinkClusterParenthetical() {
        let text = "Mars averages 140 million miles away. ([Space.com](https://space.com/mars))"
        XCTAssertEqual(AskAnswerBlock.speakableText(from: text), "Mars averages 140 million miles away.")
    }

    func testSpeakableStripsGrokClusterWithParenInURL() {
        // Wikipedia disambiguation URLs contain parens; the cluster must still fully strip
        // (no stray ")" left behind for TTS to stumble over).
        let text = "Mercury is the smallest planet. ([Wikipedia](https://en.wikipedia.org/wiki/Mercury_(planet)))"
        XCTAssertEqual(AskAnswerBlock.speakableText(from: text), "Mercury is the smallest planet.")
    }

    func testSpeakableKeepsParentheticalThatIsNotPurelyLinks() {
        // A parenthetical containing real prose must survive (only its link is normalized),
        // so the citation-cluster rule must not over-fire.
        let text = "See the chart (details in [figure 2](https://x.com/fig) below)."
        XCTAssertEqual(AskAnswerBlock.speakableText(from: text), "See the chart (details in figure 2 below).")
    }

    func testSpeakableStripsGrokTrailingPhraseLinkPointer() {
        // Grok often ends with a "<phrase>: [link]." pointer and no "Source:" keyword.
        let text = "The final is July 19. Full fixtures and results: [FIFA](https://www.fifa.com/wc2026)."
        XCTAssertEqual(AskAnswerBlock.speakableText(from: text), "The final is July 19.")
    }

    func testSpeakableStripsGrokTrailingPointerAsOwnParagraph() {
        let text = "Argentina topped the group.\n\nFull results: [ESPN](https://espn.com/wc)."
        XCTAssertEqual(AskAnswerBlock.speakableText(from: text), "Argentina topped the group.")
    }

    func testSpeakableKeepsColonClauseWithoutALink() {
        // A colon clause that isn't a citation (no link after the colon) must be kept.
        let text = "Note: bring an umbrella."
        XCTAssertEqual(AskAnswerBlock.speakableText(from: text), "Note: bring an umbrella.")
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

    // MARK: - Streaming stable prefix

    func testStablePrefixEmptyForNarrationOnly() {
        XCTAssertEqual(
            AskAnswerBlock.stableSpeakablePrefix(fromStreaming: "Searching for the weather"),
            ""
        )
    }

    func testStablePrefixStripsNarrationAndHoldsPartialSentence() {
        XCTAssertEqual(
            AskAnswerBlock.stableSpeakablePrefix(fromStreaming: "Searching for X.\nParis is nice. It sits on"),
            "Paris is nice."
        )
    }

    func testStablePrefixHoldsSentenceAtBufferEnd() {
        XCTAssertEqual(
            AskAnswerBlock.stableSpeakablePrefix(fromStreaming: "Paris is nice."),
            ""
        )
        XCTAssertEqual(
            AskAnswerBlock.stableSpeakablePrefix(fromStreaming: "Paris is nice. "),
            "Paris is nice."
        )
    }

    func testStablePrefixEmitsClosedParagraphAndStableLeadingSentences() {
        let text = "First paragraph ends here.\n\nSecond starts. Still growing"
        XCTAssertEqual(
            AskAnswerBlock.stableSpeakablePrefix(fromStreaming: text),
            "First paragraph ends here.\nSecond starts."
        )
    }

    func testStablePrefixHoldsGrowingTableLineAfterClosedParagraph() {
        let text = "Done talking.\n\n| a | b |"
        XCTAssertEqual(
            AskAnswerBlock.stableSpeakablePrefix(fromStreaming: text),
            "Done talking."
        )
    }

    func testStablePrefixEmitsClosedTableMatchingSpeakableText() {
        let tableClosed = """
        Intro line.

        | City | Country |
        | --- | --- |
        | Paris | France |
        """
        XCTAssertEqual(
            AskAnswerBlock.stableSpeakablePrefix(fromStreaming: tableClosed + "\n\nStill typing"),
            AskAnswerBlock.speakableText(from: tableClosed)
        )
    }

    func testStablePrefixSkipsGrowingAndClosedCodeBlocks() {
        let growing = "Before.\n\n```swift\nlet x = 1"
        XCTAssertEqual(AskAnswerBlock.stableSpeakablePrefix(fromStreaming: growing), "Before.")

        let closed = "Before.\n\n```swift\nlet x = 1\n```\n\nAfter. "
        XCTAssertEqual(
            AskAnswerBlock.stableSpeakablePrefix(fromStreaming: closed),
            "Before.\nAfter."
        )
    }

    func testStablePrefixDoesNotSplitDecimalInsideOpenSentence() {
        XCTAssertEqual(
            AskAnswerBlock.stableSpeakablePrefix(fromStreaming: "The answer is 3.5 and more coming"),
            ""
        )
    }

    func testStablePrefixHoldsCitationTailWhileGrowing() {
        let steps = [
            "Blah blah. Source:",
            "Blah blah. Source: [",
            "Blah blah. Source: [X](https://x.com)",
        ]
        for step in steps {
            XCTAssertEqual(
                AskAnswerBlock.stableSpeakablePrefix(fromStreaming: step),
                "Blah blah.",
                "Unexpected prefix at growth step: \(step)"
            )
        }
    }

    func testStablePrefixHoldsGrowingListThenEmitsWhenClosed() {
        let growing = "Lead in.\n\n- one\n- two"
        XCTAssertEqual(AskAnswerBlock.stableSpeakablePrefix(fromStreaming: growing), "Lead in.")

        let closed = "Lead in.\n\n- one\n- two\n\nClosing line. "
        XCTAssertEqual(
            AskAnswerBlock.stableSpeakablePrefix(fromStreaming: closed),
            AskAnswerBlock.speakableText(from: closed)
        )
    }

    // MARK: - Leading clause (opt-in)

    /// 70-char clause through the comma; full sentence continues after.
    private static let longCommaSentence =
        "The weather forecast across the region this week remains mild overall, with only occasional showers expected near the coast."

    func testLeadingClauseEmitsLongCommaThenSentenceExtendsIt() {
        // Mid-stream: comma past 60 chars + lookahead char after the space.
        let mid = "The weather forecast across the region this week remains mild overall, with only"
        let clause = AskAnswerBlock.stableSpeakablePrefix(fromStreaming: mid, allowLeadingClause: true)
        XCTAssertEqual(
            clause,
            "The weather forecast across the region this week remains mild overall,"
        )
        XCTAssertTrue(clause.hasSuffix(","))

        // Once the sentence completes (period + space + lookahead), sentence-level
        // result must extend the clause (PREFIX / monotone).
        let afterSentence = Self.longCommaSentence + " Next."
        let sentenceLevel = AskAnswerBlock.stableSpeakablePrefix(
            fromStreaming: afterSentence,
            allowLeadingClause: true
        )
        XCTAssertTrue(
            sentenceLevel.hasPrefix(clause),
            "sentence-level must extend clause: clause=\(clause) sentence=\(sentenceLevel)"
        )
        XCTAssertEqual(
            sentenceLevel,
            "The weather forecast across the region this week remains mild overall, with only occasional showers expected near the coast."
        )
    }

    func testLeadingClauseRejectsShortCommaAndMissingLookahead() {
        // Comma well before 60 chars.
        let short = "Short intro, more text arrives later and keeps going past sixty eventually."
        XCTAssertEqual(
            AskAnswerBlock.stableSpeakablePrefix(fromStreaming: short, allowLeadingClause: true),
            ""
        )

        // Boundary at end of stream: comma+space with no lookahead char after the space.
        let noLookahead =
            "The weather forecast across the region this week remains mild overall, "
        XCTAssertEqual(
            AskAnswerBlock.stableSpeakablePrefix(fromStreaming: noLookahead, allowLeadingClause: true),
            ""
        )
    }

    func testLeadingClauseSemicolonAndColonBoundaries() {
        let semicolonMid =
            "After a careful review of the available evidence from multiple teams; the committee"
        XCTAssertEqual(
            AskAnswerBlock.stableSpeakablePrefix(fromStreaming: semicolonMid, allowLeadingClause: true),
            "After a careful review of the available evidence from multiple teams;"
        )

        let colonMid =
            "Please arrive early for check-in at the main stadium gate entrance: doors open"
        XCTAssertEqual(
            AskAnswerBlock.stableSpeakablePrefix(fromStreaming: colonMid, allowLeadingClause: true),
            "Please arrive early for check-in at the main stadium gate entrance:"
        )

        // "7:30" has no space after the colon — never a clause boundary.
        let timeOfDay =
            "The shuttle leaves at 7:30 AM from the north terminal with several stops planned along the route for passengers."
        XCTAssertEqual(
            AskAnswerBlock.stableSpeakablePrefix(fromStreaming: timeOfDay, allowLeadingClause: true),
            ""
        )
    }

    func testLeadingClauseRejectsUnsafeMarkdownFragments() {
        // Markdown link spanning / inside the candidate.
        let withLink =
            "According to the detailed report available at [label](https://example.com/path), further analysis"
        XCTAssertEqual(
            AskAnswerBlock.stableSpeakablePrefix(fromStreaming: withLink, allowLeadingClause: true),
            ""
        )

        // Bare URL / http substring.
        let withHTTP =
            "See the public archive mirrored at http for the complete dataset dump, further notes"
        // Ensure length past 60 before comma: pad carefully.
        let withHTTPLong =
            "See the lengthy public archive mirrored online at http for the complete dump, further notes"
        XCTAssertEqual(
            AskAnswerBlock.stableSpeakablePrefix(fromStreaming: withHTTPLong, allowLeadingClause: true),
            ""
        )
        _ = withHTTP

        let withWWW =
            "See the lengthy public archive mirrored online at www.example for the dump, further notes"
        XCTAssertEqual(
            AskAnswerBlock.stableSpeakablePrefix(fromStreaming: withWWW, allowLeadingClause: true),
            ""
        )

        // Odd backticks.
        let oddBackticks =
            "The sample uses `code that clearly exceeds sixty characters of span, and more"
        XCTAssertEqual(
            AskAnswerBlock.stableSpeakablePrefix(fromStreaming: oddBackticks, allowLeadingClause: true),
            ""
        )

        // Odd asterisks.
        let oddStars =
            "The sample uses *emphasis that clearly exceeds sixty characters of span, and more"
        XCTAssertEqual(
            AskAnswerBlock.stableSpeakablePrefix(fromStreaming: oddStars, allowLeadingClause: true),
            ""
        )

        // Unbalanced parenthesis spanning the cut.
        let unbalanced =
            "Researchers noted a result that clearly exceeds sixty characters of length (see appendix, and then more"
        XCTAssertEqual(
            AskAnswerBlock.stableSpeakablePrefix(fromStreaming: unbalanced, allowLeadingClause: true),
            ""
        )
    }

    func testLeadingClauseRejectsGrowingFirstLineShapesAndMultiBlock() {
        // Table / list / fence / heading first-line shapes — existing guards.
        XCTAssertEqual(
            AskAnswerBlock.stableSpeakablePrefix(
                fromStreaming: "| City | Country | more cells that exceed sixty characters total here, x",
                allowLeadingClause: true
            ),
            ""
        )
        XCTAssertEqual(
            AskAnswerBlock.stableSpeakablePrefix(
                fromStreaming: "- item that is long enough to clearly exceed sixty characters of text, x",
                allowLeadingClause: true
            ),
            ""
        )
        XCTAssertEqual(
            AskAnswerBlock.stableSpeakablePrefix(
                fromStreaming: "```swift\nlet value = 1 // long enough comment past sixty chars maybe, x",
                allowLeadingClause: true
            ),
            ""
        )
        // Heading block (not a paragraph).
        XCTAssertEqual(
            AskAnswerBlock.stableSpeakablePrefix(
                fromStreaming: "## A long heading that clearly exceeds sixty characters of plain text, x",
                allowLeadingClause: true
            ),
            ""
        )

        // Two blocks present → no clause emission (even if second is growing prose).
        let twoBlocks =
            "First closed paragraph ends here.\n\nThe weather forecast across the region this week remains mild overall, with only"
        XCTAssertEqual(
            AskAnswerBlock.stableSpeakablePrefix(fromStreaming: twoBlocks, allowLeadingClause: true),
            "First closed paragraph ends here."
        )
        // Sentence-level non-empty → equals today's result; not a clause from block 2.
        XCTAssertEqual(
            AskAnswerBlock.stableSpeakablePrefix(fromStreaming: twoBlocks, allowLeadingClause: true),
            AskAnswerBlock.stableSpeakablePrefix(fromStreaming: twoBlocks, allowLeadingClause: false)
        )
    }

    func testLeadingClauseDefersToCompleteSentenceWhenAvailable() {
        let withSentence =
            "Paris is nice. It sits on the river with several notable landmarks nearby for visitors."
        let withFlag = AskAnswerBlock.stableSpeakablePrefix(
            fromStreaming: withSentence,
            allowLeadingClause: true
        )
        let withoutFlag = AskAnswerBlock.stableSpeakablePrefix(
            fromStreaming: withSentence,
            allowLeadingClause: false
        )
        XCTAssertEqual(withFlag, withoutFlag)
        XCTAssertEqual(withFlag, "Paris is nice.")
    }

    func testLeadingClauseDisabledMatchesLegacyBehaviorOnNewFixtures() {
        let fixtures = [
            Self.longCommaSentence + " Next.",
            "After a careful review of the available evidence from multiple teams; the committee endorsed the plan without further delay. ",
            "Please arrive early for check-in at the main stadium gate entrance: doors open for the public shortly after seven. ",
            "The shuttle leaves at 7:30 AM from the north terminal with several stops planned along the route for passengers. ",
            "Short intro, more text arrives later and keeps going past sixty eventually. ",
            "## A long heading that clearly exceeds sixty characters of plain text, x",
            "First closed paragraph ends here.\n\nThe weather forecast across the region this week remains mild overall, with only",
        ]
        for fixture in fixtures {
            let legacy = AskAnswerBlock.stableSpeakablePrefix(fromStreaming: fixture)
            let explicitFalse = AskAnswerBlock.stableSpeakablePrefix(
                fromStreaming: fixture,
                allowLeadingClause: false
            )
            XCTAssertEqual(legacy, explicitFalse, "default/false mismatch for: \(fixture.prefix(40))…")
            // Flag off must not produce a mid-sentence clause emission.
            if !legacy.isEmpty {
                XCTAssertFalse(
                    legacy.hasSuffix(",") && !legacy.contains("."),
                    "legacy path should not emit bare clause for: \(fixture.prefix(40))…"
                )
            }
        }

        // On the mid-stream long-comma fixture, flag false stays empty while true emits.
        let mid = "The weather forecast across the region this week remains mild overall, with only"
        XCTAssertEqual(AskAnswerBlock.stableSpeakablePrefix(fromStreaming: mid), "")
        XCTAssertEqual(
            AskAnswerBlock.stableSpeakablePrefix(fromStreaming: mid, allowLeadingClause: false),
            ""
        )
        XCTAssertFalse(
            AskAnswerBlock.stableSpeakablePrefix(fromStreaming: mid, allowLeadingClause: true).isEmpty
        )
    }

    // MARK: - Markdown span closure verification (P1 fix for attempt 2)

    func testLeadingClauseRejectsUnclosedBoldSpan() {
        // Unclosed ** before comma: even count (2 asterisks) but still open
        let unclosedBold =
            "The report shows a **bold unfinished statement here exceeds sixty characters total, more text"
        XCTAssertEqual(
            AskAnswerBlock.stableSpeakablePrefix(fromStreaming: unclosedBold, allowLeadingClause: true),
            ""
        )

        // After the closing ** arrives and sentence completes
        let closedBoldComplete =
            "The report shows a **bold unfinished statement here exceeds sixty characters total,** and more text. Next."
        let withFlag = AskAnswerBlock.stableSpeakablePrefix(
            fromStreaming: closedBoldComplete,
            allowLeadingClause: true
        )
        XCTAssertFalse(withFlag.isEmpty, "Should emit sentence once complete")
        let withoutFlag = AskAnswerBlock.stableSpeakablePrefix(
            fromStreaming: closedBoldComplete,
            allowLeadingClause: false
        )
        XCTAssertEqual(withFlag, withoutFlag)
    }

    func testLeadingClauseWithholdsClosedBoldSpanConservatively() {
        // Even a CLOSED bold span withholds clause emission: the guard is
        // delimiter-free by policy (span-closure proofs kept leaking — see
        // isMarkdownStableClauseFragment). The sentence-level path still
        // emits once the sentence completes.
        let closedBold =
            "The analysis concludes that **yes**, this clearly exceeds sixty characters of text, next sentence"
        XCTAssertEqual(
            AskAnswerBlock.stableSpeakablePrefix(fromStreaming: closedBold, allowLeadingClause: true),
            ""
        )

        let completed = closedBold + " arrives now. Next."
        let sentenceLevel = AskAnswerBlock.stableSpeakablePrefix(
            fromStreaming: completed,
            allowLeadingClause: true
        )
        XCTAssertFalse(sentenceLevel.isEmpty, "sentence path must still emit once complete")
        XCTAssertFalse(sentenceLevel.contains("**"), "bold markers stripped in sentence path")
    }

    func testLeadingClauseRejectsUnclosedBacktickSpan() {
        // Unclosed backtick before comma: odd count but the span never closes
        let unclosedCode =
            "The function uses `code_span that remains open across this clause boundary here exceeds chars, next"
        XCTAssertEqual(
            AskAnswerBlock.stableSpeakablePrefix(fromStreaming: unclosedCode, allowLeadingClause: true),
            ""
        )
    }

    func testLeadingClauseWithholdsClosedBacktickSpanConservatively() {
        // Closed code spans also withhold (delimiter-free guard policy).
        let closedCode =
            "The `getData()` function is declared in the main file and is available for use across many systems, more text"
        XCTAssertEqual(
            AskAnswerBlock.stableSpeakablePrefix(fromStreaming: closedCode, allowLeadingClause: true),
            ""
        )
    }

    func testLeadingClauseRejectsEmphasisCharacterInsideClosedCodeSpan() {
        // Arbiter-review counterexample: the strip regex KEEPS code-span inner
        // content as literal text, so a `*` inside a closed code span can pair
        // with a later `*emphasis*` and mutate the already-emitted region.
        // Delimiter-free rejection covers this class by construction.
        let starInCode =
            "The helper `a*b` computes a quick product for callers across the module, then more"
        XCTAssertEqual(
            AskAnswerBlock.stableSpeakablePrefix(fromStreaming: starInCode, allowLeadingClause: true),
            ""
        )

        // Invariant check for the full divergent continuation.
        let full = "The helper `a*b` computes a quick product for callers across the module, "
            + "then multiplies by a *scaling* factor before returning. Next."
        let streamed = AskAnswerBlock.stableSpeakablePrefix(fromStreaming: full, allowLeadingClause: true)
        XCTAssertTrue(
            AskAnswerBlock.speakableText(from: full).hasPrefix(streamed),
            "streamed prefix must remain a prefix of the final speakable text"
        )
    }

    func testLeadingClauseRejectsUnclosedUnderscoreSpan() {
        // Unclosed single underscore before comma
        let unclosedEmph =
            "The _emphasis here is not closed and continues across this boundary, more text"
        XCTAssertEqual(
            AskAnswerBlock.stableSpeakablePrefix(fromStreaming: unclosedEmph, allowLeadingClause: true),
            ""
        )
    }

    func testLeadingClauseWithholdsClosedUnderscoreSpanConservatively() {
        // Closed emphasis spans also withhold (delimiter-free guard policy).
        let closedEmph =
            "The _current_ implementation works well and is available for all users here, more text"
        XCTAssertEqual(
            AskAnswerBlock.stableSpeakablePrefix(fromStreaming: closedEmph, allowLeadingClause: true),
            ""
        )
    }

    func testLeadingClauseRejectsUnclosedDoubleUnderscoreSpan() {
        // Unclosed __ before comma
        let unclosedStrong =
            "The __strong emphasis here is not closed and continues across this boundary, more text"
        XCTAssertEqual(
            AskAnswerBlock.stableSpeakablePrefix(fromStreaming: unclosedStrong, allowLeadingClause: true),
            ""
        )
    }

    func testLeadingClauseWithholdsClosedDoubleUnderscoreSpanConservatively() {
        // Closed strong-emphasis spans also withhold (delimiter-free guard policy).
        let closedStrong =
            "The __critical__ point here is available and well documented for all implementations, next sentence"
        XCTAssertEqual(
            AskAnswerBlock.stableSpeakablePrefix(fromStreaming: closedStrong, allowLeadingClause: true),
            ""
        )
    }

    func testLeadingClauseRejectsAdjacentEmptyDelimiterPairs() {
        let adjacentBackticks =
            "The report includes ```` beside an unusually detailed explanation for everyone, more text"
        XCTAssertEqual(
            AskAnswerBlock.stableSpeakablePrefix(
                fromStreaming: adjacentBackticks,
                allowLeadingClause: true
            ),
            ""
        )

        // A later closing pair must not retroactively change an emitted prefix.
        let laterBacktickPair = adjacentBackticks + " arrives before the real closing pair `` and conclusion. Next."
        let laterResult = AskAnswerBlock.stableSpeakablePrefix(
            fromStreaming: laterBacktickPair,
            allowLeadingClause: false
        )
        XCTAssertTrue(AskAnswerBlock.speakableText(from: laterBacktickPair).hasPrefix(laterResult))

        let adjacentAsterisks =
            "The report includes **** beside an unusually detailed explanation for everyone, more text"
        XCTAssertEqual(
            AskAnswerBlock.stableSpeakablePrefix(
                fromStreaming: adjacentAsterisks,
                allowLeadingClause: true
            ),
            ""
        )
    }
    // MARK: - Glued sentences and fused narration

    func testRepairGluedSentences() {
        // Boundary across a delta join.
        XCTAssertEqual(
            AskAnswerBlock.repairGluedSentences(previous: "the next matches.", delta: "Context is mid-July"),
            " Context is mid-July"
        )
        // Internal glue inside one delta.
        XCTAssertEqual(
            AskAnswerBlock.repairGluedSentences(previous: "", delta: "in the tournament.Next up: the semi-finals."),
            "in the tournament. Next up: the semi-finals."
        )
        // Digit before the terminator still repairs.
        XCTAssertEqual(
            AskAnswerBlock.repairGluedSentences(previous: "", delta: "on July 15, 2026.The final follows."),
            "on July 15, 2026. The final follows."
        )
        // Guards: initialisms, domains, decimals, identifiers untouched.
        XCTAssertEqual(
            AskAnswerBlock.repairGluedSentences(previous: "", delta: "the U.S.Army and FIFA.com and 3.5 grams of Node.js"),
            "the U.S.Army and FIFA.com and 3.5 grams of Node.js"
        )
        // Uppercase before the terminator (initialism tail) blocks the join repair.
        XCTAssertEqual(
            AskAnswerBlock.repairGluedSentences(previous: "check FIFA.", delta: "Com now"),
            "Com now"
        )
        // Plain start, no previous text: untouched.
        XCTAssertEqual(
            AskAnswerBlock.repairGluedSentences(previous: "", delta: "Hello there."),
            "Hello there."
        )
    }

    func testStrippingFusedLeadingNarrationSentences() {
        // The field case: preamble sentences fused into the same paragraph as
        // the answer (post glue-repair).
        let fused = "I'll look up the current FIFA World Cup 2026 schedule for the next matches. "
            + "Context is mid-July 2026 — checking which matches are next. "
            + "Next up: the semi-finals. The first is today."
        XCTAssertEqual(
            AskAnswerBlock.strippingLeadingNarration(fused),
            "Next up: the semi-finals. The first is today."
        )

        // Any "I'll …" opener strips, not just an enumerated verb list —
        // this exact case survived the verb whack-a-mole in the field.
        let pullCase = "I'll pull the latest AI headlines for today. Today's AI snapshot (July 14, 2026): news follows."
        XCTAssertEqual(
            AskAnswerBlock.strippingLeadingNarration(pullCase),
            "Today's AI snapshot (July 14, 2026): news follows."
        )

        // Never reduces an answer to nothing.
        let onlyNarration = "I'll look up the schedule."
        XCTAssertEqual(AskAnswerBlock.strippingLeadingNarration(onlyNarration), onlyNarration)

        // Ambiguous sentence openers stay: this is prose, not narration.
        let prose = "Checking the weather is easy. Just look outside."
        XCTAssertEqual(AskAnswerBlock.strippingLeadingNarration(prose), prose)

        // Initialisms inside a narration sentence don't cut it short.
        XCTAssertEqual(
            AskAnswerBlock.strippingLeadingNarration("I'll check U.S. sources for this. The answer is 42."),
            "The answer is 42."
        )
    }

    func testRepairGluedSentencesThroughMarkdownDelimiters() {
        // grok glues its narration segment straight onto a bold answer opener
        // ("rankings.**Tokyo") — the delimiter run must not hide the boundary.
        XCTAssertEqual(
            AskAnswerBlock.repairGluedSentences(
                previous: "",
                delta: "vs metro rankings.**Tokyo, Osaka, and Nagoya** lead."
            ),
            "vs metro rankings. **Tokyo, Osaka, and Nagoya** lead."
        )
        // Same shape when the bold opener starts a fresh delta.
        XCTAssertEqual(
            AskAnswerBlock.repairGluedSentences(
                previous: "vs metro rankings.",
                delta: "**Tokyo, Osaka, and Nagoya** lead."
            ),
            " **Tokyo, Osaka, and Nagoya** lead."
        )
        // Bold digits (version fragments) stay glued: the capital requirement holds.
        XCTAssertEqual(
            AskAnswerBlock.repairGluedSentences(previous: "", delta: "shipped in v2.**8** today"),
            "shipped in v2.**8** today"
        )
        // A join landing INSIDE the delimiter run is left alone (documented
        // limitation: no insertion point can match the whole-text repair).
        XCTAssertEqual(
            AskAnswerBlock.repairGluedSentences(previous: "vs metro rankings.*", delta: "*Tokyo leads."),
            "*Tokyo leads."
        )
    }

    func testStripsBareGerundResearchNarration() {
        // The exact field shape (2026-07-14): verbless research-gerund
        // sentences fused ahead of a bold answer, post glue-repair.
        let japan = "Checking current city-population rankings for Japan. "
            + "Confirming city-proper vs metro rankings. "
            + "**Tokyo, Osaka, and Nagoya** — Japan's three largest urban areas by population."
        XCTAssertEqual(
            AskAnswerBlock.strippingLeadingNarration(japan),
            "**Tokyo, Osaka, and Nagoya** — Japan's three largest urban areas by population."
        )

        let everest = "Checking the currently accepted official height of Mount Everest. "
            + "**Mount Everest is 8,848.86 meters (29,031.7 feet) tall.**"
        XCTAssertEqual(
            AskAnswerBlock.strippingLeadingNarration(everest),
            "**Mount Everest is 8,848.86 meters (29,031.7 feet) tall.**"
        )

        // A gerund-subject sentence with a conjugated verb is prose — kept.
        let prose = "Verifying a backup takes about a minute. Run the restore check monthly."
        XCTAssertEqual(AskAnswerBlock.strippingLeadingNarration(prose), prose)

        // Same guard at line granularity: a short gerund-opener LINE that
        // reads as prose survives even with content below it.
        let proseLines = "Checking the weather is easy.\nJust look outside."
        XCTAssertEqual(AskAnswerBlock.strippingLeadingNarration(proseLines), proseLines)
    }

    // MARK: - Streaming: unclosed inline spans withhold

    func testBoldSpanningSentencesWithholdsUntilCloserArrives() {
        // Mid-span: sentence one is complete but the bold that started before
        // it is still open — emitting would speak literal asterisks and later
        // strip differently (MONOTONE break). Must emit nothing from the span.
        let midSpan = "**First we ship the fix. Then we watch"
        XCTAssertEqual(AskAnswerBlock.stableSpeakablePrefix(fromStreaming: midSpan), "")

        // "closely.**" is not a raw sentence boundary (no space after the
        // period), so emission resumes at the NEXT boundary after the span
        // closes — everything through it emits together, stripped clean.
        let closed = "**First we ship the fix. Then we watch closely.** After that arrives more. X"
        let stable = AskAnswerBlock.stableSpeakablePrefix(fromStreaming: closed)
        XCTAssertEqual(
            stable,
            "First we ship the fix. Then we watch closely. After that arrives more."
        )
        XCTAssertFalse(stable.contains("*"))
    }

    func testCleanLeadingSentenceStillEmitsWhileLaterSpanIsOpen() {
        // Only the span-crossing tail is withheld — a clean first sentence
        // ahead of the open span keeps streaming.
        let text = "The rollout starts today. **First we ship. Then we"
        XCTAssertEqual(
            AskAnswerBlock.stableSpeakablePrefix(fromStreaming: text),
            "The rollout starts today."
        )
    }

    // MARK: - Streaming stable prefix: property tests

    private static let monotoneFixtureA = """
        Searching for the weather in Paris.
        Paris is mild in spring. Summers can be warm.
        Pack a light jacket just in case.
        """

    private static let monotoneFixtureB = """
        Here are two cities.

        | City | Country |
        | --- | --- |
        | Paris | France |
        | Rome | Italy |

        Both are worth visiting.
        """

    private static let monotoneFixtureC = """
        The launch is Monday.
        - backup window Tuesday
        - scrub possible

        Source: [NASA](https://nasa.gov/x)
        """

    private func assertMonotoneStreamingPrefix(fixture: String, file: StaticString = #file, line: UInt = #line) {
        var previous = ""
        var lengths: [Int] = Array(stride(from: 7, through: fixture.count, by: 7))
        if lengths.last != fixture.count {
            lengths.append(fixture.count)
        }
        for len in lengths {
            let prefix = String(fixture.prefix(len))
            let result = AskAnswerBlock.stableSpeakablePrefix(fromStreaming: prefix)
            XCTAssertTrue(
                result.hasPrefix(previous),
                "Monotone violation at length \(len): previous=\(previous) result=\(result)",
                file: file,
                line: line
            )
            previous = result
        }
    }

    private func assertConvergentStreamingPrefix(fixture: String, file: StaticString = #file, line: UInt = #line) {
        let finalSpeakable = AskAnswerBlock.speakableText(from: fixture)
        var lengths: [Int] = Array(stride(from: 7, through: fixture.count, by: 7))
        if lengths.last != fixture.count {
            lengths.append(fixture.count)
        }
        for len in lengths {
            let prefix = String(fixture.prefix(len))
            let stable = AskAnswerBlock.stableSpeakablePrefix(fromStreaming: prefix)
            XCTAssertTrue(
                finalSpeakable.hasPrefix(stable),
                "Convergent violation at length \(len): stable=\(stable) final=\(finalSpeakable)",
                file: file,
                line: line
            )
        }

        let closed = fixture + "\n\nDone. "
        XCTAssertEqual(
            AskAnswerBlock.stableSpeakablePrefix(fromStreaming: closed),
            AskAnswerBlock.speakableText(from: closed),
            file: file,
            line: line
        )
    }

    func testStablePrefixMonotoneFixtureA() {
        assertMonotoneStreamingPrefix(fixture: Self.monotoneFixtureA)
    }

    func testStablePrefixMonotoneFixtureB() {
        assertMonotoneStreamingPrefix(fixture: Self.monotoneFixtureB)
    }

    func testStablePrefixMonotoneFixtureC() {
        assertMonotoneStreamingPrefix(fixture: Self.monotoneFixtureC)
    }

    func testStablePrefixConvergentFixtureA() {
        assertConvergentStreamingPrefix(fixture: Self.monotoneFixtureA)
    }

    func testStablePrefixConvergentFixtureB() {
        assertConvergentStreamingPrefix(fixture: Self.monotoneFixtureB)
    }

    func testStablePrefixConvergentFixtureC() {
        assertConvergentStreamingPrefix(fixture: Self.monotoneFixtureC)
    }

    func testStablePrefixStopsAtUnsafeMiddleBlockInsteadOfSkipping() {
        // A paragraph that still looks like a table opener ("|…|") is withheld
        // from streaming, but speakableText DOES speak it — so streaming must
        // STOP there, not skip it and emit later blocks. Skipping would make
        // the streamed output a non-prefix of the final speakable text and
        // corrupt the completion handoff's consumed-prefix arithmetic.
        let fixture = "First part is prose.\n\n|stray pipe line|\n\nLast part is prose."
        let streamed = AskAnswerBlock.stableSpeakablePrefix(fromStreaming: fixture)
        let full = AskAnswerBlock.speakableText(from: fixture)

        XCTAssertTrue(full.hasPrefix(streamed),
                      "streamed must remain a prefix of the full speakable text")
        XCTAssertFalse(streamed.contains("Last part"),
                       "blocks after the withheld one must not be emitted")
        // The prefix property must also hold at every cumulative step.
        assertMonotoneStreamingPrefix(fixture: fixture)
        assertConvergentStreamingPrefixWithoutClosureEquality(fixture: fixture)
    }

    /// Prefix-at-every-step check for fixtures where an emission-unsafe block
    /// legitimately prevents sentinel-closure equality.
    private func assertConvergentStreamingPrefixWithoutClosureEquality(
        fixture: String, file: StaticString = #file, line: UInt = #line
    ) {
        let finalSpeakable = AskAnswerBlock.speakableText(from: fixture)
        var lengths: [Int] = Array(stride(from: 7, through: fixture.count, by: 7))
        if lengths.last != fixture.count { lengths.append(fixture.count) }
        for len in lengths {
            let prefix = String(fixture.prefix(len))
            let stable = AskAnswerBlock.stableSpeakablePrefix(fromStreaming: prefix)
            XCTAssertTrue(finalSpeakable.hasPrefix(stable),
                          "Prefix violation at length \(len): stable=\(stable)",
                          file: file, line: line)
        }
    }

    // MARK: - Leading clause: streaming property tests

    /// Corpus for clause-aware streaming: plain prose, links, bold/italic, inline
    /// code, numbered list, table, citations, and a Sources trailer.
    private static let leadingClausePropertyFixtures: [(name: String, text: String)] = [
        (
            "plain_prose",
            """
            The weather forecast across the region this week remains mild overall, with only occasional showers expected near the coast. Pack a light jacket just in case you go out after dusk.
            """
        ),
        (
            "bold_spanning_sentences",
            """
            The plan is straightforward from here on out. **First we ship the fix today. Then we watch the telemetry closely.** After that the rollout continues as scheduled next week.
            """
        ),
        (
            "markdown_links",
            """
            According to [Reuters](https://reuters.com/article/x), the launch window opens Monday morning with a backup on Tuesday. Full coverage is on their site.
            """
        ),
        (
            "bold_italic",
            """
            The **primary** recommendation is simple and clear for most travelers, while _secondary_ tips cover packing layers near the waterfront each evening.
            """
        ),
        (
            "inline_code",
            """
            Use the `encode` helper when you prepare the payload for the client, then verify the checksum before you ship the binary to production systems.
            """
        ),
        (
            "numbered_list",
            """
            Follow these steps carefully before you begin the migration process today.

            1. Back up the database and export a cold snapshot
            2. Apply the schema migration during a quiet maintenance window
            3. Verify application health checks after traffic returns
            """
        ),
        (
            "table",
            """
            Here are two cities worth visiting this spring season overall.

            | City | Country |
            | --- | --- |
            | Paris | France |
            | Rome | Italy |

            Both reward a slow afternoon walk through the historic center.
            """
        ),
        (
            "citations",
            """
            Mars averages about 140 million miles away from Earth [1]. The exact distance varies with orbital position across the year.
            """
        ),
        (
            "sources_trailer",
            """
            Chiropractic was founded in 1895 and spread through clinics worldwide over the following decades.

            Sources
            - [Palmer](https://example.com/palmer)
            - [History](https://example.com/history)
            """
        ),
        (
            "bold_span_crossing_comma",
            """
            The recommendation is clearly important and **this statement about the matter crosses the boundary**, so the next sentence follows. Additional details may apply.
            """
        ),
        (
            "adjacent_backtick_pairs",
            """
            The report includes ```` beside an unusually detailed explanation for everyone, more text arrives before the real closing pair `` and conclusion. Additional details may apply.
            """
        ),
    ]

    func testLeadingClauseStreamingPropertyMonotoneAndPrefix() {
        for (name, fixture) in Self.leadingClausePropertyFixtures {
            let finalSpeakable = AskAnswerBlock.speakableText(from: fixture)
            var previousNonEmpty = ""
            var hasEmitted = false
            var offset = 0
            while offset <= fixture.count {
                let prefix = String(fixture.prefix(offset))
                let result = AskAnswerBlock.stableSpeakablePrefix(
                    fromStreaming: prefix,
                    allowLeadingClause: !hasEmitted
                )
                XCTAssertTrue(
                    finalSpeakable.hasPrefix(result),
                    "PREFIX violation fixture=\(name) offset=\(offset) result=«\(result)» final=«\(finalSpeakable)» prefixTail=«\(prefix.suffix(60))»"
                )
                if !result.isEmpty {
                    XCTAssertTrue(
                        result.hasPrefix(previousNonEmpty),
                        "MONOTONE violation fixture=\(name) offset=\(offset) previous=«\(previousNonEmpty)» result=«\(result)»"
                    )
                    previousNonEmpty = result
                    hasEmitted = true
                }
                if offset == fixture.count { break }
                let step = 1 + (offset % 7) // 1...7 character appends
                offset = min(offset + step, fixture.count)
            }
        }
    }
}
