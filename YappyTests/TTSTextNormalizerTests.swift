//
//  TTSTextNormalizerTests.swift
//  YappyTests
//

import XCTest
@testable import Yappy

final class TTSTextNormalizerTests: XCTestCase {
    private struct Case {
        let input: String
        let expected: String
        let line: UInt

        init(_ input: String, _ expected: String, line: UInt = #line) {
            self.input = input
            self.expected = expected
            self.line = line
        }
    }

    private func assertCases(_ cases: [Case]) {
        for testCase in cases {
            XCTAssertEqual(
                TTSTextNormalizer.normalize(testCase.input),
                testCase.expected,
                "input: \(testCase.input)",
                line: testCase.line
            )
        }
    }

    func testYearRanges() {
        assertCases([
            Case("1843–1907", "1843 to 1907"),
            Case("1843-1907", "1843 to 1907"),
            Case("1843—1907", "1843 to 1907"),
            Case("1914–18", "1914 to 1918"),
            Case("1918–14", "1918–14")
        ])
    }

    func testOtherNumericRanges() {
        assertCases([
            Case("34–35 million", "34 to 35 million")
        ])
    }

    func testTimes() {
        assertCases([
            Case("8:00 PM", "8 PM"),
            Case("3:05", "3 oh 5"),
            Case("3:30", "3 30"),
            Case("16:9", "16 9"),
            Case("8:00–9:30 PM", "8 to 9 30 PM")
        ])
    }

    func testApproximateTilde() {
        assertCases([
            Case("~140", "about 140"),
            Case("~ 140", "about 140")
        ])
    }

    func testDegrees() {
        assertCases([
            Case("20°C", "20 degrees Celsius"),
            Case("68°F", "68 degrees Fahrenheit"),
            Case("30°", "30 degrees")
        ])
    }

    func testRomanNumerals() {
        assertCases([
            Case("War II", "War 2"),
            Case("Henry VIII", "Henry 8"),
            Case("Type IV", "Type 4"),
            Case("WWII", "World War 2"),
            Case("WWI", "World War 1"),
            Case("Henry I", "Henry I")
        ])
    }

    func testFractions() {
        assertCases([
            Case("1/2", "one half"),
            Case("1/3", "one third"),
            Case("2/3", "two thirds"),
            Case("1/4", "one quarter"),
            Case("3/4", "three quarters")
        ])
    }

    func testUnitAbbreviations() {
        assertCases([
            Case("5 mi", "5 miles"),
            Case("140 million mi", "140 million miles"),
            Case("about 250 million mi away", "about 250 million miles away"),
            Case("5 km", "5 kilometers"),
            Case("60 mph", "60 miles per hour"),
            Case("60 km/h", "60 kilometers per hour"),
            Case("60 kph", "60 kilometers per hour"),
            Case("5 ft", "5 feet"),
            Case("5 kg", "5 kilograms"),
            Case("5 lb", "5 pounds"),
            Case("5 lbs", "5 pounds"),
            Case("5 mm", "5 millimeters"),
            Case("5 cm", "5 centimeters"),
            Case("5 ms", "5 milliseconds"),
            Case("5 Hz", "5 hertz"),
            Case("5 kHz", "5 kilohertz"),
            Case("5 MHz", "5 megahertz"),
            Case("5 GHz", "5 gigahertz"),
            Case("5 KB", "5 kilobytes"),
            Case("5 MB", "5 megabytes"),
            Case("5 GB", "5 gigabytes"),
            Case("5 TB", "5 terabytes")
        ])
    }

    func testMagnitudeSuffixes() {
        assertCases([
            Case("$500M", "$500 million"),
            Case("500K", "500 thousand"),
            Case("2B", "2 billion"),
            Case("3T", "3 trillion"),
            Case("2bn", "2 billion"),
            Case("3tn", "3 trillion")
        ])
    }

    func testGuardsLeaveCorrectlyHandledTextUntouched() {
        assertCases([
            // ISO dates were once a leave-alone guard against the year-range
            // rule; R18 now deliberately speaks them as real dates.
            Case("2026-07-08", "July eighth, 2026"),
            Case("1,845", "1,845"),
            Case("1845", "1845"),
            Case("the 1990s", "the 1990s"),
            Case("$5.3 billion", "$5.3 billion"),
            Case("Henry I", "Henry I"),
            Case("45%", "45%")
        ])
    }

    func testDates() {
        assertCases([
            // Conversions
            Case("September 1, 1939", "September first, 1939"),
            Case("July 4", "July fourth"),
            Case("May 25, 2026", "May twenty-fifth, 2026"),
            Case("December 31", "December thirty-first"),
            Case("1 September 1939", "first September 1939"),
            Case("3 May 2026", "third May 2026"),
            Case("22 June 1941", "twenty-second June 1941"),
            Case("July 8, 2026", "July eighth, 2026"),
            // Guards: must stay unchanged
            Case("September 2024", "September 2024"),
            Case("the 1990s", "the 1990s"),
            Case("Chapter 11", "Chapter 11"),
            Case("Room 12", "Room 12"),
            Case("9/11", "9/11"),
            Case("September 1-3", "September 1-3")
        ])
    }

    func testCalendarAbbreviations() {
        assertCases([
            // Month + day flows into R10's ordinals.
            Case("Fri Jul 17", "Friday July seventeenth"),
            Case("Sat Jul 18", "Saturday July eighteenth"),
            Case("Tue, Jul 15", "Tuesday, July fifteenth"),
            Case("arriving 17 Jul", "arriving seventeenth July"),
            Case("due Sept 2026", "due September 2026"),
            Case("Jul. 4 fireworks", "July fourth fireworks"),
            // Weekday with a bare day number or table-style colon.
            Case("Sat 18 works", "Saturday 18 works"),
            Case("Sun: mostly cloudy", "Sunday: mostly cloudy"),
            Case("Tue: rain", "Tuesday: rain"),
            // Ranges.
            Case("open Mon–Fri", "open Monday to Friday"),
            Case("Jul–Aug heat", "July to August heat"),
            Case("Fri - Sun getaway", "Friday to Sunday getaway"),
            // Guards: must stay unchanged
            Case("Jan wrote the memo", "Jan wrote the memo"),
            Case("the sun is out", "the sun is out"),
            Case("he sat down", "he sat down"),
            Case("they wed in spring", "they wed in spring"),
            Case("APR of 24%", "APR of 24%"),
            Case("mar the finish", "mar the finish"),
            Case("Sun rises in the east", "Sun rises in the east")
        ])
    }

    func testComparisonSymbols() {
        assertCases([
            Case("temps > 90 today", "temps more than 90 today"),
            Case("keep it < 5 percent", "keep it under 5 percent"),
            Case("scores ≥ 80", "scores at least 80"),
            Case("doses ≤ 10", "doses at most 10"),
            Case(">50% turnout", ">50% turnout") // no left operand: untouched
        ])
    }

    func testLeadingMinus() {
        assertCases([
            Case("it was -5°F outside", "it was minus 5 degrees Fahrenheit outside"),
            Case("-40 in Yakutsk", "minus 40 in Yakutsk"),
            // Guards: must stay unchanged
            // Spaced hyphen is ambiguous (range vs subtraction) — untouched.
            Case("10 - 5 leaves 5", "10 - 5 leaves 5"),
            Case("a 9-5 job", "a 9-5 job"),
            Case("pre-2020 rules", "pre-2020 rules")
        ])
    }

    func testISODates() {
        assertCases([
            Case("released 2026-07-14", "released July fourteenth, 2026"),
            Case("due 2025-01-02 sharp", "due January second, 2025 sharp"),
            // Guards: must stay unchanged
            Case("part 555-01-99", "part 555-01-99"),
            Case("bad month 2026-13-01", "bad month 2026-13-01")
        ])
    }

    func testPlaceAbbreviations() {
        assertCases([
            Case("St. Louis is great", "Saint Louis is great"),
            Case("on Main St. downtown", "on Main Street downtown"),
            Case("Main St. Then we left", "Main Street. Then we left"),
            Case("Mt. Everest looms", "Mount Everest looms"),
            Case("Ft. Worth grew", "Fort Worth grew"),
            // Ambiguous with no capitalized neighbor: untouched.
            Case("the st. is unclear", "the st. is unclear")
        ])
    }

    func testHourAbbreviations() {
        assertCases([
            Case("3 hrs of work", "3 hours of work"),
            Case("1 hr left", "1 hour left"),
            // Guards: must stay unchanged
            Case("the hr department", "the hr department")
        ])
    }

    func testShorthandWords() {
        assertCases([
            Case("w/ extra cheese", "with extra cheese"),
            Case("w/o delay", "without delay"),
            Case("approx. 40 people", "approximately 40 people"),
            Case("Approx. half stayed", "Approximately half stayed")
        ])
    }

    func testMultiplierX() {
        assertCases([
            Case("2x faster now", "2 times faster now"),
            Case("grew 4x since", "grew 4 times since"),
            Case("a 3.5x gain", "a 3.5 times gain"),
            Case("1920x1080 display", "1920 by 1080 display"),
            // Guards: must stay unchanged
            Case("offset 0x1F set", "offset 0x1F set"),
            Case("x marks the spot", "x marks the spot")
        ])
    }

    func testNumberSign() {
        assertCases([
            Case("#1 in the league", "number 1 in the league"),
            // Guards: must stay unchanged
            Case("C# code", "C# code")
        ])
    }

    func testWordRangeDash() {
        assertCases([
            Case("the Boston–NYC flight", "the Boston to NYC flight"),
            // Guards: must stay unchanged
            Case("growth—driven by demand", "growth—driven by demand"),
            Case("a north–south route", "a north–south route")
        ])
    }

    func testEmojiStripped() {
        assertCases([
            Case("Great news 🎉 today", "Great news today"),
            Case("Done ✅", "Done "),
            Case("thumbs 👍🏽 up", "thumbs up"),
            // Guards: digits and plain punctuation survive
            Case("route 66 stays", "route 66 stays")
        ])
    }

    func testEqualEnDashRangeStays() {
        assertCases([
            Case("a 50–50 split", "a 50–50 split"),
            Case("odds 60–40 tonight", "odds 60 to 40 tonight")
        ])
    }

    func testApproximateTildeBeyondDigits() {
        assertCases([
            Case("~$5 billion", "about $5 billion"),
            Case("~mid-July", "about mid-July"),
            Case("~140", "about 140"),
            // Guards: must stay unchanged
            Case("~/Library/Logs", "~/Library/Logs")
        ])
    }

    func testLatinAbbreviations() {
        assertCases([
            Case("many breeds, e.g., corgis", "many breeds, for example, corgis"),
            Case("some fruit (e.g. apples)", "some fruit (for example apples)"),
            Case("E.g., start small", "For example, start small"),
            Case("the total, i.e. everything", "the total, that is everything"),
            Case("I.e. the whole thing", "That is the whole thing"),
            // Guards: must stay unchanged
            Case("the variable eg is set", "the variable eg is set")
        ])
    }

    func testSpacedSlashBecomesPause() {
        assertCases([
            Case("High / Low", "High, Low"),
            Case("65 / 54", "65, 54"),
            // Guards: must stay unchanged
            Case("9/11", "9/11"),
            Case("either/or", "either/or")
        ])
    }

    func testMarkdownResidue() {
        assertCases([
            // Leaked emphasis markers are never spoken.
            Case("**Bold** stays bold", "Bold stays bold"),
            Case("**Unclosed lead-in", "Unclosed lead-in"),
            Case("trailing** residue", "trailing residue"),
            Case("a *single* star", "a single star"),
            Case("`code` span", "code span"),
            Case("stray ` backtick", "stray backtick"),
            // A star between digits is arithmetic, not markdown.
            Case("5 * 3", "5 times 3"),
            Case("5*3", "5 times 3"),
            // Guards: must stay unchanged
            Case("plain prose stays put", "plain prose stays put")
        ])
    }

    func testVersusAbbreviation() {
        assertCases([
            Case("Lakers vs. Celtics", "Lakers versus Celtics"),
            Case("speed vs quality", "speed versus quality"),
            Case("Apples Vs. Oranges", "Apples versus Oranges"),
            Case("A vs B", "A versus B"),
            // Guards: must stay unchanged
            Case("VS Code", "VS Code"),
            Case("the two Vs", "the two Vs"),
            Case("vsync issues", "vsync issues"),
            Case("Vs alone capitalized", "Vs alone capitalized")
        ])
    }
}
