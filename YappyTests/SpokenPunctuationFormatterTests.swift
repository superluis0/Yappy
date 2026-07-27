//
//  SpokenPunctuationFormatterTests.swift
//  YappyTests
//

import XCTest
@testable import Yappy

final class SpokenPunctuationFormatterTests: XCTestCase {

    private func f(_ s: String) -> String { SpokenPunctuationFormatter.apply(s) }

    func testComma() {
        XCTAssertEqual(f("hello comma world"), "hello, world")
    }

    func testPeriodStartsNewSentence() {
        XCTAssertEqual(f("done period next thought"), "done. Next thought")
    }

    func testQuestionMark() {
        XCTAssertEqual(f("is this real question mark"), "is this real?")
    }

    func testExclamationMarkAndPoint() {
        XCTAssertEqual(f("wow exclamation mark"), "wow!")
        XCTAssertEqual(f("wow exclamation point"), "wow!")
    }

    func testFullStop() {
        XCTAssertEqual(f("okay full stop"), "okay.")
    }

    func testColonAndSemicolon() {
        XCTAssertEqual(f("items colon x semicolon y"), "items: x; y")
    }

    // "a" is a determiner, so the noun guard keeps the mark word literal —
    // "a semicolon" reads as the noun. Single-letter list items ("a; b") are
    // the accepted false negative; see nounDeterminers.
    func testDeterminerBeforeMarkKeepsItLiteral() {
        XCTAssertEqual(f("items colon a semicolon b"), "items: a semicolon b")
    }

    func testParentheses() {
        XCTAssertEqual(f("see open paren note close paren here"), "see (note) here")
    }

    func testHyphenGlues() {
        XCTAssertEqual(f("x hyphen y"), "x-y")
    }

    // MARK: - Whole-word safety

    func testPluralIsNotConverted() {
        XCTAssertEqual(f("the commas are wrong"), "the commas are wrong")
    }

    func testMarkWordEmbeddedIsNotConverted() {
        XCTAssertEqual(f("a periodic table"), "a periodic table")
    }

    func testHalfOfTwoWordMarkIsSafe() {
        XCTAssertEqual(f("what is the question"), "what is the question")
    }

    func testNoTriggerIsIdentity() {
        XCTAssertEqual(f("just a normal sentence"), "just a normal sentence")
    }

    // MARK: - Extended marks

    func testApostropheGlues() {
        XCTAssertEqual(f("it apostrophe s working"), "it's working")
    }

    func testEllipsis() {
        XCTAssertEqual(f("wait ellipsis really"), "wait… really")
    }

    func testEmDashGlues() {
        XCTAssertEqual(f("yes em dash no"), "yes—no")
    }

    func testForwardSlashGlues() {
        XCTAssertEqual(f("a forward slash b"), "a/b")
    }

    func testQuotes() {
        XCTAssertEqual(f("he said open quote hi close quote"), "he said \u{201C}hi\u{201D}")
    }

    // A bare "quote" / "slash" stays prose — only the two-word forms convert.
    func testBareQuoteWordIsNotConverted() {
        XCTAssertEqual(f("the famous quote is here"), "the famous quote is here")
    }

    // MARK: - Determiner prose guard (literal nouns)

    /// Single-word marks after a determiner that cannot end a sentence stay as
    /// ordinary words ("her period", "a dash of salt").
    func testDeterminerKeepsSingleWordMarkAsLiteralNoun() {
        XCTAssertEqual(f("she missed her period"), "she missed her period")
        XCTAssertEqual(f("add a dash of salt"), "add a dash of salt")
        XCTAssertEqual(f("put a comma there"), "put a comma there")
        XCTAssertEqual(f("the doctor checked his colon"), "the doctor checked his colon")
        XCTAssertEqual(f("we entered a period of growth"), "we entered a period of growth")
        XCTAssertEqual(f("every semicolon matters"), "every semicolon matters")
    }

    /// Real punctuation commands still convert when no (or the wrong kind of)
    /// determiner precedes them.
    func testDeterminerGuardDoesNotSuppressRealCommands() {
        // One-token window: "the" belongs to "store", not "comma".
        XCTAssertEqual(
            f("i went to the store comma then i left"),
            "i went to the store, then i left"
        )
        // Demonstratives are excluded — "that period" is a real command.
        XCTAssertEqual(f("i don't like that period"), "i don't like that.")
        // Existing multi-mark / two-word behavior stays put.
        XCTAssertEqual(f("hello comma world question mark"), "hello, world?")
        XCTAssertEqual(f("see open paren note close paren"), "see (note)")
        // Start of text / no preceding determiner still converts.
        XCTAssertEqual(f("period thanks"), ". Thanks")
        XCTAssertEqual(f("done period next thought"), "done. Next thought")
    }

    /// The four determiners that CAN legitimately end a sentence, so a real
    /// punctuation command after one of them is suppressed. This is a known,
    /// deliberate false negative — pinned here so removing an entry from
    /// `nounDeterminers` is a conscious decision with a failing test attached,
    /// not a silent change. The trade is argued in that set's doc comment: the
    /// reverse error deletes words while still reading as valid English, which
    /// is far harder for the user to catch than a stray literal "period".
    func testAcceptedFalseNegativesAfterSentenceFinalDeterminers() {
        XCTAssertEqual(f("i gave it to her period"), "i gave it to her period")
        XCTAssertEqual(f("the book is his period"), "the book is his period")
        XCTAssertEqual(f("they cost five dollars each period"),
                       "they cost five dollars each period")
        XCTAssertEqual(f("i'll take another period"), "i'll take another period")
    }

    /// The cases those four entries exist to protect — the reverse error, where
    /// an unguarded mark word silently eats a noun and still reads as English.
    func testSentenceFinalDeterminersStillProtectTheirNounCases() {
        XCTAssertEqual(f("each period lasts twenty minutes"),
                       "each period lasts twenty minutes")
        XCTAssertEqual(f("another dash of salt"), "another dash of salt")
    }

    /// Direct unit coverage for the lookback helper.
    func testStaysLiteralNounLookback() {
        let tokens = TranscriptTokenizer.tokenize("her period")
        // tokens: word("her"), gap(" "), word("period")
        XCTAssertTrue(SpokenPunctuationFormatter.staysLiteralNoun(tokens: tokens, index: 2))
        XCTAssertFalse(SpokenPunctuationFormatter.staysLiteralNoun(tokens: tokens, index: 0))

        let command = TranscriptTokenizer.tokenize("store comma")
        XCTAssertFalse(SpokenPunctuationFormatter.staysLiteralNoun(tokens: command, index: 2))

        let demonstrative = TranscriptTokenizer.tokenize("that period")
        XCTAssertFalse(SpokenPunctuationFormatter.staysLiteralNoun(tokens: demonstrative, index: 2))

        // Gap with punctuation is not skipped.
        let punctGap = TranscriptTokenizer.tokenize("a, period")
        // word("a"), gap(", "), word("period") — gap is not space-only.
        if case .gap(let gap) = punctGap[1] {
            XCTAssertFalse(TranscriptTokenizer.isSpaceOnly(gap))
        } else {
            XCTFail("expected gap after a")
        }
        XCTAssertFalse(SpokenPunctuationFormatter.staysLiteralNoun(tokens: punctGap, index: 2))
    }

    /// Every symbol-producing spoken form must pass the substring triggers gate;
    /// otherwise the formatter returns the input unchanged.
    func testEverySymbolMapEntryIsCoveredBySubstringTriggers() {
        let cases: [(input: String, expected: String)] = [
            ("hello comma world", "hello, world"),
            ("done period next", "done. Next"),
            ("items colon a", "items: a"),
            // Non-determiner before semicolon so the map/trigger still fire
            // (bare "a semicolon" stays literal — see testDeterminerBeforeMarkKeepsItLiteral).
            ("x semicolon y", "x; y"),
            ("x hyphen y", "x-y"),
            ("x dash y", "x-y"),
            ("it apostrophe s", "it's"),
            ("wait ellipsis really", "wait… really"),
            ("is this real question mark", "is this real?"),
            ("wow exclamation mark", "wow!"),
            ("wow exclamation point", "wow!"),
            ("okay full stop", "okay."),
            ("see open paren note close paren", "see (note)"),
            ("see open parenthesis note close parenthesis", "see (note)"),
            ("see open bracket note close bracket", "see [note]"),
            ("he said open quote hi close quote", "he said \u{201C}hi\u{201D}"),
            ("he said open quote hi end quote", "he said \u{201C}hi\u{201D}"),
            ("a forward slash b", "a/b"),
            ("yes em dash no", "yes—no")
        ]
        for item in cases {
            let result = f(item.input)
            XCTAssertEqual(
                result,
                item.expected,
                "trigger gate or map miss for \(item.input.debugDescription)"
            )
        }
    }
}
