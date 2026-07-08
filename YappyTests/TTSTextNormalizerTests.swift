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
            Case("1918–14", "1918–14"),
        ])
    }

    func testOtherNumericRanges() {
        assertCases([
            Case("34–35 million", "34 to 35 million"),
        ])
    }

    func testTimes() {
        assertCases([
            Case("8:00 PM", "8 PM"),
            Case("3:05", "3 oh 5"),
            Case("3:30", "3 30"),
            Case("16:9", "16 9"),
            Case("8:00–9:30 PM", "8 to 9 30 PM"),
        ])
    }

    func testApproximateTilde() {
        assertCases([
            Case("~140", "about 140"),
            Case("~ 140", "about 140"),
        ])
    }

    func testDegrees() {
        assertCases([
            Case("20°C", "20 degrees Celsius"),
            Case("68°F", "68 degrees Fahrenheit"),
            Case("30°", "30 degrees"),
        ])
    }

    func testRomanNumerals() {
        assertCases([
            Case("War II", "War 2"),
            Case("Henry VIII", "Henry 8"),
            Case("Type IV", "Type 4"),
            Case("WWII", "World War 2"),
            Case("WWI", "World War 1"),
            Case("Henry I", "Henry I"),
        ])
    }

    func testFractions() {
        assertCases([
            Case("1/2", "one half"),
            Case("1/3", "one third"),
            Case("2/3", "two thirds"),
            Case("1/4", "one quarter"),
            Case("3/4", "three quarters"),
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
            Case("5 TB", "5 terabytes"),
        ])
    }

    func testMagnitudeSuffixes() {
        assertCases([
            Case("$500M", "$500 million"),
            Case("500K", "500 thousand"),
            Case("2B", "2 billion"),
            Case("3T", "3 trillion"),
            Case("2bn", "2 billion"),
            Case("3tn", "3 trillion"),
        ])
    }

    func testGuardsLeaveCorrectlyHandledTextUntouched() {
        assertCases([
            Case("2026-07-08", "2026-07-08"),
            Case("1,845", "1,845"),
            Case("1845", "1845"),
            Case("the 1990s", "the 1990s"),
            Case("$5.3 billion", "$5.3 billion"),
            Case("Henry I", "Henry I"),
            Case("45%", "45%"),
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
            Case("September 1-3", "September 1-3"),
        ])
    }
}
