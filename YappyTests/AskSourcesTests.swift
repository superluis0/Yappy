//
//  AskSourcesTests.swift
//  YappyTests
//

import XCTest
@testable import Yappy

final class AskSourcesTests: XCTestCase {
    func testMarkdownLinkAndBareURL() {
        let sources = AskSources.extract(from:
            "See https://www.reuters.com/x and [Apple](https://apple.com/y)."
        )
        XCTAssertEqual(sources.map(\.host), ["reuters.com", "apple.com"])
        XCTAssertEqual(sources[0].url.absoluteString, "https://www.reuters.com/x")
        XCTAssertEqual(sources[1].url.absoluteString, "https://apple.com/y")
    }

    func testStripsTrailingPunctuationFromBareURLs() {
        let sources = AskSources.extract(from:
            "Refs: https://example.com/a), https://news.com/b.; https://docs.com/c>."
        )
        XCTAssertEqual(sources.map(\.host), ["example.com", "news.com", "docs.com"])
        XCTAssertEqual(sources[0].url.absoluteString, "https://example.com/a")
        XCTAssertEqual(sources[1].url.absoluteString, "https://news.com/b")
        XCTAssertEqual(sources[2].url.absoluteString, "https://docs.com/c")
    }

    func testStripsTrailingEllipsis() {
        let sources = AskSources.extract(from: "More at https://example.com/path…")
        XCTAssertEqual(sources.count, 1)
        XCTAssertEqual(sources[0].url.absoluteString, "https://example.com/path")
    }

    func testStripsLeadingWWWFromHost() {
        let sources = AskSources.extract(from: "https://www.bbc.co.uk/news")
        XCTAssertEqual(sources.map(\.host), ["bbc.co.uk"])
    }

    func testDedupesByHostKeepingFirstURL() {
        let sources = AskSources.extract(from: """
            First https://apple.com/alpha
            Second https://www.apple.com/beta
            Third [Docs](https://apple.com/gamma)
            """)
        XCTAssertEqual(sources.count, 1)
        XCTAssertEqual(sources[0].host, "apple.com")
        XCTAssertEqual(sources[0].url.absoluteString, "https://apple.com/alpha")
    }

    func testPreservesFirstAppearanceOrder() {
        let sources = AskSources.extract(from: """
            [Zebra](https://z.com/1) then https://a.com/2 then https://m.com/3
            """)
        XCTAssertEqual(sources.map(\.host), ["z.com", "a.com", "m.com"])
    }

    func testCapsAtFiveSources() {
        let sources = AskSources.extract(from: """
            https://one.com/1 https://two.com/2 https://three.com/3
            https://four.com/4 https://five.com/5 https://six.com/6
            """)
        XCTAssertEqual(sources.count, 5)
        XCTAssertEqual(sources.map(\.host), ["one.com", "two.com", "three.com", "four.com", "five.com"])
    }

    func testIgnoresURLsInsideFencedCodeBlocks() {
        let sources = AskSources.extract(from: """
            Real https://visible.com/a

            ```
            ignore https://hidden.com/x
            [Also](https://also.hidden.com/y)
            ```

            Also https://second.com/b
            """)
        XCTAssertEqual(sources.map(\.host), ["visible.com", "second.com"])
    }

    func testEmptyAndNoURLAnswersReturnEmpty() {
        XCTAssertTrue(AskSources.extract(from: "").isEmpty)
        XCTAssertTrue(AskSources.extract(from: "No links here — just prose.").isEmpty)
        XCTAssertTrue(AskSources.extract(from: "[not a link](mailto:a@b.com)").isEmpty)
    }
    func testPlainHTTPLinksAreNotExtracted() {
        let sources = AskSources.extract(from: "See [a](http://insecure.example/x) and https://ok.dev/b")
        XCTAssertEqual(sources.map(\.host), ["ok.dev"])
    }

}