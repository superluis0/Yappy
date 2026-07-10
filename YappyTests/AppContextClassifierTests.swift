//
//  AppContextClassifierTests.swift
//  YappyTests
//

import XCTest
@testable import Yappy

final class AppContextClassifierTests: XCTestCase {

    func testKnownCategories() {
        XCTAssertEqual(AppContextClassifier.category(forBundleID: "com.apple.mail"), .email)
        XCTAssertEqual(AppContextClassifier.category(forBundleID: "com.tinyspeck.slackmacgap"), .workChat)
        XCTAssertEqual(AppContextClassifier.category(forBundleID: "com.apple.MobileSMS"), .personalChat)
        XCTAssertEqual(AppContextClassifier.category(forBundleID: "com.apple.dt.Xcode"), .code)
    }

    func testUnknownAndNilFallBackToOther() {
        XCTAssertEqual(AppContextClassifier.category(forBundleID: "com.unknown.app"), .other)
        XCTAssertEqual(AppContextClassifier.category(forBundleID: nil), .other)
    }

    func testCategoryDefaultTones() {
        XCTAssertEqual(AppCategory.email.defaultTone, .formal)
        XCTAssertEqual(AppCategory.workChat.defaultTone, .formal)
        XCTAssertEqual(AppCategory.personalChat.defaultTone, .casual)
        XCTAssertEqual(AppCategory.code.defaultTone, .verbatim)
        XCTAssertEqual(AppCategory.other.defaultTone, .formal)
    }

    // MARK: - FocusedFieldClassifier (pure role/subrole mapping)

    func testSearchSubroleMapsToSearch() {
        XCTAssertEqual(FocusedFieldClassifier.kind(role: "AXTextField", subrole: "AXSearchField"), .search)
        // Subrole wins even without a recognized role.
        XCTAssertEqual(FocusedFieldClassifier.kind(role: nil, subrole: "AXSearchField"), .search)
    }

    func testTextAreaMapsToMultiLine() {
        XCTAssertEqual(FocusedFieldClassifier.kind(role: "AXTextArea", subrole: nil), .multiLine)
    }

    func testTextFieldMapsToSingleLine() {
        XCTAssertEqual(FocusedFieldClassifier.kind(role: "AXTextField", subrole: nil), .singleLine)
    }

    func testUnknownAndNilRolesMapToUnknown() {
        XCTAssertEqual(FocusedFieldClassifier.kind(role: "AXStaticText", subrole: nil), .unknown)
        XCTAssertEqual(FocusedFieldClassifier.kind(role: "AXButton", subrole: "AXSomethingElse"), .unknown)
        XCTAssertEqual(FocusedFieldClassifier.kind(role: nil, subrole: nil), .unknown)
    }

    func testSecureFieldMapsToSecure() {
        // Reported as a subrole on a text field...
        XCTAssertEqual(FocusedFieldClassifier.kind(role: "AXTextField", subrole: "AXSecureTextField"), .secure)
        // ...or as the role itself, depending on the app — both must map to .secure.
        XCTAssertEqual(FocusedFieldClassifier.kind(role: "AXSecureTextField", subrole: nil), .secure)
        // Secure dominates over an otherwise-recognized search subrole.
        XCTAssertEqual(FocusedFieldClassifier.kind(role: "AXSecureTextField", subrole: "AXSearchField"), .secure)
    }

    // MARK: - Single-line collapse (used for single-line / search fields)

    func testCollapseFlattensNewlinesToSingleSpaces() {
        XCTAssertEqual(
            FocusedFieldClassifier.collapseToSingleLine("first line\nsecond line"),
            "first line second line")
    }

    func testCollapseCollapsesRunsOfWhitespace() {
        XCTAssertEqual(
            FocusedFieldClassifier.collapseToSingleLine("hello   world"),
            "hello world")
        XCTAssertEqual(
            FocusedFieldClassifier.collapseToSingleLine("a\n\n\nb\t c"),
            "a b c")
    }

    func testCollapseTrimsLeadingAndTrailingWhitespace() {
        XCTAssertEqual(
            FocusedFieldClassifier.collapseToSingleLine("  \n padded \n "),
            "padded")
    }

    func testCollapseIsIdempotentOnAlreadyCleanText() {
        let clean = "already a single clean line"
        XCTAssertEqual(FocusedFieldClassifier.collapseToSingleLine(clean), clean)
    }

    // MARK: - Tone transform: formalize (whitelisted contractions, case-preserving)

    func testFormalizeWhitelistedContractionsCasePreserving() {
        // lowercase source -> stored lowercase expansion + terminal "."
        XCTAssertEqual(ToneStyle.formalize("don't"), "do not.")
        XCTAssertEqual(ToneStyle.formalize("Don't"), "Do not.")
        XCTAssertEqual(ToneStyle.formalize("I don't think so"), "I do not think so.")
        XCTAssertEqual(ToneStyle.formalize("She doesn't know"), "She does not know.")
        XCTAssertEqual(ToneStyle.formalize("He didn't ask"), "He did not ask.")
        XCTAssertEqual(ToneStyle.formalize("I can't go"), "I cannot go.")
        XCTAssertEqual(ToneStyle.formalize("Can't stop"), "Cannot stop.")
        XCTAssertEqual(ToneStyle.formalize("We won't wait"), "We will not wait.")
        XCTAssertEqual(ToneStyle.formalize("It isn't ready"), "It is not ready.")
        XCTAssertEqual(ToneStyle.formalize("They aren't here"), "They are not here.")
        XCTAssertEqual(ToneStyle.formalize("It wasn't me"), "It was not me.")
        XCTAssertEqual(ToneStyle.formalize("They weren't ready"), "They were not ready.")
        XCTAssertEqual(ToneStyle.formalize("We couldn't tell"), "We could not tell.")
        XCTAssertEqual(ToneStyle.formalize("You shouldn't worry"), "You should not worry.")
        XCTAssertEqual(ToneStyle.formalize("I wouldn't say that"), "I would not say that.")
        XCTAssertEqual(ToneStyle.formalize("We haven't shipped"), "We have not shipped.")
        XCTAssertEqual(ToneStyle.formalize("It hasn't landed"), "It has not landed.")
        XCTAssertEqual(ToneStyle.formalize("She hadn't seen it"), "She had not seen it.")
        XCTAssertEqual(ToneStyle.formalize("I'm here"), "I am here.")
        // lowercase source still keeps the always-capital pronoun "I".
        XCTAssertEqual(ToneStyle.formalize("i'm here"), "I am here.")
        XCTAssertEqual(ToneStyle.formalize("I've done it"), "I have done it.")
        XCTAssertEqual(ToneStyle.formalize("I'll go"), "I will go.")
        XCTAssertEqual(ToneStyle.formalize("We're on it"), "We are on it.")
        XCTAssertEqual(ToneStyle.formalize("We've moved"), "We have moved.")
        XCTAssertEqual(ToneStyle.formalize("We'll see"), "We will see.")
        XCTAssertEqual(ToneStyle.formalize("They're late"), "They are late.")
        XCTAssertEqual(ToneStyle.formalize("They've left"), "They have left.")
        XCTAssertEqual(ToneStyle.formalize("They'll come"), "They will come.")
        XCTAssertEqual(ToneStyle.formalize("You're right"), "You are right.")
        XCTAssertEqual(ToneStyle.formalize("You've won"), "You have won.")
        XCTAssertEqual(ToneStyle.formalize("You'll like it"), "You will like it.")
        XCTAssertEqual(ToneStyle.formalize("It's ready"), "It is ready.")
        XCTAssertEqual(ToneStyle.formalize("That's fine"), "That is fine.")
        XCTAssertEqual(ToneStyle.formalize("There's a bug"), "There is a bug.")
        XCTAssertEqual(ToneStyle.formalize("What's next"), "What is next.")
        XCTAssertEqual(ToneStyle.formalize("Who's there"), "Who is there.")
        XCTAssertEqual(ToneStyle.formalize("Let's go"), "Let us go.")
    }

    func testFormalizeLeavesAmbiguousContractionsUntouched() {
        // Ambiguous 's (possessive / he's-she's = is/has) and all 'd (had/would).
        XCTAssertEqual(ToneStyle.formalize("The dog's leash"), "The dog's leash.")
        XCTAssertEqual(ToneStyle.formalize("She's leaving"), "She's leaving.")
        XCTAssertEqual(ToneStyle.formalize("He's late"), "He's late.")
        XCTAssertEqual(ToneStyle.formalize("The boss's plan"), "The boss's plan.")
        XCTAssertEqual(ToneStyle.formalize("I'd say yes"), "I'd say yes.")
        XCTAssertEqual(ToneStyle.formalize("We'd go"), "We'd go.")
        XCTAssertEqual(ToneStyle.formalize("You'd know"), "You'd know.")
        XCTAssertEqual(ToneStyle.formalize("They'd agree"), "They'd agree.")
        // "cannot" is deliberately left as-is (not re-expanded).
        XCTAssertEqual(ToneStyle.formalize("cannot stop"), "cannot stop.")
    }

    func testFormalizeLeavesNonWhitelistRegisterWordsUntouched() {
        XCTAssertEqual(ToneStyle.formalize("I'm gonna do it"), "I am gonna do it.")
        XCTAssertEqual(ToneStyle.formalize("kinda works"), "kinda works.")
    }

    func testFormalizeTerminalPunctuation() {
        XCTAssertEqual(ToneStyle.formalize("hello"), "hello.")
        XCTAssertEqual(ToneStyle.formalize("chapter 3"), "chapter 3.")
        XCTAssertEqual(ToneStyle.formalize("Ready?"), "Ready?")
        XCTAssertEqual(ToneStyle.formalize("Go!"), "Go!")
        XCTAssertEqual(ToneStyle.formalize("Done."), "Done.")
        XCTAssertEqual(ToneStyle.formalize(""), "")
        // Contraction at end still gets terminal punctuation after expansion.
        XCTAssertEqual(ToneStyle.formalize("I think we can't"), "I think we cannot.")
    }

    // MARK: - Tone transform: casualize (trailing-period rules)

    func testCasualizeStripsTrailingPeriodOnQualifyingText() {
        XCTAssertEqual(ToneStyle.casualize("Sounds good."), "Sounds good")
        XCTAssertEqual(ToneStyle.casualize("See you tomorrow."), "See you tomorrow")
        XCTAssertEqual(ToneStyle.casualize("Ok."), "Ok")
        XCTAssertEqual(ToneStyle.casualize("On my way."), "On my way")
        XCTAssertEqual(ToneStyle.casualize("Great."), "Great")
    }

    func testCasualizeKeepsTextWhenAPredicateFails() {
        XCTAssertEqual(ToneStyle.casualize("Sounds good!"), "Sounds good!")
        XCTAssertEqual(ToneStyle.casualize("Ready?"), "Ready?")
        XCTAssertEqual(ToneStyle.casualize("Let's grab lunch. I'm starving."),
                       "Let's grab lunch. I'm starving.")
        XCTAssertEqual(
            ToneStyle.casualize("Yeah that works for me but let me double check the calendar first."),
            "Yeah that works for me but let me double check the calendar first.")
        XCTAssertEqual(ToneStyle.casualize("Line one\nLine two."), "Line one\nLine two.")
        XCTAssertEqual(ToneStyle.casualize("no period here"), "no period here")
        XCTAssertEqual(ToneStyle.casualize("The build shipped in v2.4."),
                       "The build shipped in v2.4.")
    }

    func testCasualizeWordCountBoundary() {
        // Exactly 12 words strips; 13 keeps.
        XCTAssertEqual(
            ToneStyle.casualize("one two three four five six seven eight nine ten eleven twelve."),
            "one two three four five six seven eight nine ten eleven twelve")
        XCTAssertEqual(
            ToneStyle.casualize("one two three four five six seven eight nine ten eleven twelve thirteen."),
            "one two three four five six seven eight nine ten eleven twelve thirteen.")
    }

    // MARK: - Tone transform: idempotency

    func testFormalizeIsIdempotent() {
        let inputs = [
            "don't", "I'm here", "The dog's leash", "hello", "Ready?",
            "I think we can't", "Let's go", "cannot stop",
        ]
        for input in inputs {
            let once = ToneStyle.formalize(input)
            XCTAssertEqual(ToneStyle.formalize(once), once, "formalize not idempotent for \(input)")
        }
    }

    func testCasualizeIsIdempotent() {
        let inputs = ["Sounds good.", "Ready?", "Sounds good!", "no period", "Great."]
        for input in inputs {
            let once = ToneStyle.casualize(input)
            XCTAssertEqual(ToneStyle.casualize(once), once, "casualize not idempotent for \(input)")
        }
    }

    // MARK: - Tone transform: ToneStyle.apply routing

    func testApplyRoutesToneToTransform() {
        XCTAssertEqual(ToneStyle.formal.apply(to: "don't"), "do not.")
        XCTAssertEqual(ToneStyle.casual.apply(to: "Sounds good."), "Sounds good")
    }

    func testApplyVerbatimPassesTextThroughUnchanged() {
        // Verbatim never transforms — even text a formal/casual pass would touch.
        XCTAssertEqual(ToneStyle.verbatim.apply(to: "don't"), "don't")
        XCTAssertEqual(ToneStyle.verbatim.apply(to: "Sounds good."), "Sounds good.")
        XCTAssertEqual(ToneStyle.verbatim.apply(to: "hello world"), "hello world")
    }

    // MARK: - ToneStyle Codable migration (legacy "excited" -> .casual)

    func testDecodingLegacyExcitedMigratesToCasual() throws {
        // A persisted blob (modes.json / tone overrides) carrying the removed
        // "excited" value must decode to a surviving case, not throw.
        let json = Data("\"excited\"".utf8)
        let decoded = try JSONDecoder().decode(ToneStyle.self, from: json)
        XCTAssertEqual(decoded, .casual)
    }

    func testDecodingKnownToneValuesRoundTrips() throws {
        for tone in ToneStyle.allCases {
            let encoded = try JSONEncoder().encode(tone)
            let decoded = try JSONDecoder().decode(ToneStyle.self, from: encoded)
            XCTAssertEqual(decoded, tone)
        }
    }

    func testDecodingUnknownToneValueThrows() {
        let json = Data("\"nonsense\"".utf8)
        XCTAssertThrowsError(try JSONDecoder().decode(ToneStyle.self, from: json))
    }
}
