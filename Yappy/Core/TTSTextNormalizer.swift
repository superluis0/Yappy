//
//  TTSTextNormalizer.swift
//  Yappy
//
//  Deterministic pre-synthesis text normalizer for the Kokoro TTS pipeline.
//  Empirical G2P probing found specific text shapes that misaki's grapheme-to-
//  phoneme conversion (or the espeak fallback it falls through to) mispronounces
//  even though the surrounding prose reads fine. Each rule below documents the
//  exact mispronunciation it fixes. Deliberately narrow and additive: plain
//  years, dates, currency, percents, and decades are already handled correctly
//  by the G2P and must pass through untouched.
//

import Foundation

enum TTSTextNormalizer {
    /// Applies all normalization rules, in order, to text about to be spoken.
    static func normalize(_ text: String) -> String {
        var output = text
        output = applyYearRanges(output)          // R1
        output = applyNumericRanges(output)        // R2
        output = output.replacingOccurrences(of: rejectedYearRangeMarker, with: "")
        output = applyTimes(output)                // R3
        output = applyApproximateTilde(output)     // R4
        output = applyDegrees(output)              // R5
        output = applyRomanNumerals(output)        // R6
        output = applyFractions(output)            // R7
        output = applyUnitAbbreviations(output)    // R8
        output = applyMagnitudeSuffixes(output)    // R9
        output = applyDateOrdinals(output)         // R10
        return output
    }

    // MARK: - R1: Year ranges

    /// Zero-width private-use sentinel inserted around a rejected (reversed)
    /// year-range match so R2's generic numeric-range rule can't re-match the
    /// same dash and rewrite it anyway. Stripped out right after R2 runs.
    private static let rejectedYearRangeMarker = "\u{E000}"

    /// "1843–1907" (en-dash), "1843-1907" (hyphen), or "1843—1907" (em-dash) is
    /// read digit-by-digit by the espeak fallback ("one thousand eight hundred
    /// and forty-three…") instead of as two spoken years. Rewrites to
    /// "1843 to 1907". A 2-digit second year is expanded using the first year's
    /// century ("1914–18" → "1914 to 1918"); if the expansion would be earlier
    /// than the first year (a reversed/non-range pattern like "1918–14"), the
    /// match is left untouched. The negative lookahead after the 2-digit form
    /// keeps ISO dates like "2026-07-08" from ever matching.
    private static func applyYearRanges(_ text: String) -> String {
        let pattern = #"\b(1[0-9]{3}|20[0-9]{2})[ \t]*[-–—][ \t]*(?:([0-9]{2})(?!\d|[-–—])|([0-9]{4}))\b"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        let nsText = text as NSString
        var result = ""
        var lastEnd = 0
        for match in regex.matches(in: text, range: NSRange(location: 0, length: nsText.length)) {
            let fullRange = match.range
            result += nsText.substring(with: NSRange(location: lastEnd, length: fullRange.location - lastEnd))

            let matchedText = nsText.substring(with: fullRange)
            let firstYearString = nsText.substring(with: match.range(at: 1))
            guard let firstYear = Int(firstYearString) else {
                result += protectFromNumericRangeRewrite(matchedText)
                lastEnd = fullRange.location + fullRange.length
                continue
            }

            let secondYear: Int
            if match.range(at: 2).location != NSNotFound {
                let twoDigits = nsText.substring(with: match.range(at: 2))
                guard let suffix = Int(twoDigits) else {
                    result += protectFromNumericRangeRewrite(matchedText)
                    lastEnd = fullRange.location + fullRange.length
                    continue
                }
                let century = (firstYear / 100) * 100
                secondYear = century + suffix
            } else {
                guard let fourDigits = Int(nsText.substring(with: match.range(at: 3))) else {
                    result += protectFromNumericRangeRewrite(matchedText)
                    lastEnd = fullRange.location + fullRange.length
                    continue
                }
                secondYear = fourDigits
            }

            if secondYear < firstYear {
                result += protectFromNumericRangeRewrite(matchedText)
            } else {
                result += "\(firstYear) to \(secondYear)"
            }
            lastEnd = fullRange.location + fullRange.length
        }
        result += nsText.substring(from: lastEnd)
        return result
    }

    /// Splits a rejected year-range match right after its leading digit run
    /// and inserts the sentinel there, so R2's `\d+…\d+` numeric-range pattern
    /// no longer sees contiguous digits butted up against the dash.
    private static func protectFromNumericRangeRewrite(_ matchedText: String) -> String {
        let leadingDigits = matchedText.prefix(while: \.isNumber)
        let rest = matchedText.dropFirst(leadingDigits.count)
        return "\(leadingDigits)\(rejectedYearRangeMarker)\(rest)"
    }

    // MARK: - R2: Other numeric ranges (en/em-dash only)

    /// "34–35 million" is read as "thirty-four dash thirty-five million" (or
    /// similar) instead of "34 to 35 million". Restricted to en/em-dash — a
    /// plain hyphen is used for too many non-range constructs (compound
    /// modifiers, negative numbers) to safely rewrite. Runs after R1 so year
    /// ranges are already resolved and won't double-match here.
    private static func applyNumericRanges(_ text: String) -> String {
        replace(
            text,
            pattern: #"\b(\d+(?:\.\d+)?)[ \t]*[–—][ \t]*(\d+(?:\.\d+)?)\b"#,
            template: "$1 to $2"
        )
    }

    // MARK: - R3: Times

    /// "8:00 PM" is read "eight zero zero" instead of "eight PM". Minutes "00"
    /// drop entirely ("8:00 PM" → "8 PM"); minutes of the form "0M" read as
    /// "oh M" ("3:05" → "3 oh 5"); otherwise the minutes are spoken as a plain
    /// number ("3:30" → "3 30", "16:9" → "16 9"). The lookahead excludes
    /// "H:MM:SS"-shaped strings (never followed by another ":digit").
    private static func applyTimes(_ text: String) -> String {
        let pattern = #"\b(\d{1,2}):(\d{1,2})\b(?!:\d)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        let nsText = text as NSString
        var result = ""
        var lastEnd = 0
        for match in regex.matches(in: text, range: NSRange(location: 0, length: nsText.length)) {
            let fullRange = match.range
            result += nsText.substring(with: NSRange(location: lastEnd, length: fullRange.location - lastEnd))

            let hour = nsText.substring(with: match.range(at: 1))
            let minutes = nsText.substring(with: match.range(at: 2))
            if minutes == "00" {
                result += hour
            } else if minutes.hasPrefix("0") {
                let secondDigit = minutes.dropFirst()
                result += "\(hour) oh \(secondDigit)"
            } else {
                result += "\(hour) \(minutes)"
            }
            lastEnd = fullRange.location + fullRange.length
        }
        result += nsText.substring(from: lastEnd)
        return result
    }

    // MARK: - R4: Approximate tilde

    /// "~140" is read as "tilde one hundred forty" instead of "about 140".
    private static func applyApproximateTilde(_ text: String) -> String {
        replace(text, pattern: #"~[ \t]*(?=\d)"#, template: "about ")
    }

    // MARK: - R5: Degrees

    /// "°C"/"°F" read as "see"/"eff" (the degree sign is silently dropped and
    /// only the bare letter is spoken); a lone "°" is dropped entirely. Rewrites
    /// to full words and collapses any doubled spaces the substitution creates.
    private static func applyDegrees(_ text: String) -> String {
        var output = text
        output = output.replacingOccurrences(of: "\u{00B0}C", with: " degrees Celsius")
        output = output.replacingOccurrences(of: "\u{00B0}F", with: " degrees Fahrenheit")
        output = output.replacingOccurrences(of: "\u{00B0}", with: " degrees")
        output = replace(output, pattern: #"[ \t]{2,}"#, template: " ")
        return output
    }

    // MARK: - R6: Roman numerals

    /// "War II", "Henry VIII", "Type IV" read as "eye eye", "vee eye eye eye"
    /// etc. instead of the ordinal digit. Restricted to an explicit allowlist
    /// (deliberately excluding standalone I, V, X, which are far too likely to
    /// be real words/letters) and only fires when preceded by a capitalized
    /// word, so ordinary text is untouched. "WWII"/"WWI" are handled as
    /// literal tokens since they don't fit the "word + numeral" shape.
    private static func applyRomanNumerals(_ text: String) -> String {
        var output = text
        output = replace(output, pattern: #"\bWWII\b"#, template: "World War 2")
        output = replace(output, pattern: #"\bWWI\b"#, template: "World War 1")

        let numerals: [(String, String)] = [
            ("XVIII", "18"), ("XVII", "17"), ("XVI", "16"), ("XIX", "19"),
            ("XIV", "14"), ("XV", "15"), ("XII", "12"), ("XIII", "13"),
            ("XX", "20"), ("XI", "11"),
            ("VIII", "8"), ("VII", "7"), ("VI", "6"),
            ("IV", "4"), ("IX", "9"),
            ("III", "3"), ("II", "2"),
        ]
        for (roman, digits) in numerals {
            // ICU (NSRegularExpression) lookbehind requires a bounded length,
            // so the preceding-word match is capped rather than using `*`.
            let pattern = #"(?<=[A-Z][a-zA-Z]{0,30}[ \t])\#(roman)\b"#
            output = replace(output, pattern: pattern, template: digits)
        }
        return output
    }

    // MARK: - R7: Fractions

    /// "1/2" is read "one two" instead of "one half". Standalone only — not
    /// adjacent to another digit or slash — so dates ("7/8/2026") and other
    /// slash-separated numbers are left alone. No generic a/b rule; only this
    /// fixed set of common fractions.
    private static func applyFractions(_ text: String) -> String {
        let fractions: [(String, String)] = [
            ("1/2", "one half"),
            ("1/3", "one third"),
            ("2/3", "two thirds"),
            ("1/4", "one quarter"),
            ("3/4", "three quarters"),
        ]
        var output = text
        for (fraction, words) in fractions {
            let escaped = NSRegularExpression.escapedPattern(for: fraction)
            let pattern = #"(?<![\d/])\#(escaped)(?![\d/])"#
            output = replace(output, pattern: pattern, template: words)
        }
        return output
    }

    // MARK: - R8: Unit abbreviations

    /// "5 mi" reads "five mee" instead of "five miles"; similar garbling for
    /// other abbreviated units. Only expands directly after a number or a
    /// magnitude word ("140 million mi") and only for this exact-case
    /// allowlist — bare "m" and "in" are excluded because they're too
    /// ambiguous (meter vs. the word "m", inch vs. "in").
    private static func applyUnitAbbreviations(_ text: String) -> String {
        let units: [(String, String)] = [
            ("km/h", "kilometers per hour"),
            ("kph", "kilometers per hour"),
            ("mph", "miles per hour"),
            ("mi", "miles"),
            ("km", "kilometers"),
            ("ft", "feet"),
            ("kg", "kilograms"),
            ("lbs", "pounds"),
            ("lb", "pounds"),
            ("mm", "millimeters"),
            ("cm", "centimeters"),
            ("ms", "milliseconds"),
            ("Hz", "hertz"),
            ("kHz", "kilohertz"),
            ("MHz", "megahertz"),
            ("GHz", "gigahertz"),
            ("KB", "kilobytes"),
            ("MB", "megabytes"),
            ("GB", "gigabytes"),
            ("TB", "terabytes"),
        ]
        var output = text
        for (abbreviation, expansion) in units {
            let escaped = NSRegularExpression.escapedPattern(for: abbreviation)
            let pattern = #"(?<=\d|hundred|thousand|million|billion|trillion)[ \t]\#(escaped)\b"#
            output = replace(output, pattern: pattern, template: " \(expansion)")
        }
        return output
    }

    // MARK: - R9: Magnitude suffixes

    /// "$500M" reads the bare letter "em" instead of "million". Expands
    /// uppercase K/M/B/T and lowercase "bn"/"tn" immediately after a number
    /// (optionally $-prefixed) into the full word, keeping any leading "$" so
    /// the G2P's own currency handling (already correct) still fires.
    private static func applyMagnitudeSuffixes(_ text: String) -> String {
        var output = text
        let suffixes: [(String, String)] = [
            ("K", " thousand"),
            ("M", " million"),
            ("B", " billion"),
            ("T", " trillion"),
            ("bn", " billion"),
            ("tn", " trillion"),
        ]
        for (suffix, expansion) in suffixes {
            let escaped = NSRegularExpression.escapedPattern(for: suffix)
            let pattern = #"(?<=\d)\#(escaped)\b"#
            output = replace(output, pattern: pattern, template: expansion)
        }
        return output
    }

    // MARK: - R10: Date ordinals

    /// Month names/abbreviations recognized by both date shapes below.
    private static let dateMonthNames = "January|February|March|April|May|June|July|August|September|October|November|December|Jan|Feb|Mar|Apr|Jun|Jul|Aug|Sep|Sept|Oct|Nov|Dec"

    /// "September 1" is read as "September ONE" (and "1 September" as "ONE
    /// September") by Kokoro's G2P instead of the natural ordinal reading,
    /// "September first". Runs both a US month-first shape and an
    /// international day-first shape for robustness - even though the answer
    /// contract now pins Ask's own output to US month-day-year order, TTS may
    /// still be asked to speak text from elsewhere. Restricted to a
    /// plausible day-of-month (1...31) via `dayOrdinal(_:)`, which never
    /// matches a 4-digit year, so years are read correctly as before.
    private static func applyDateOrdinals(_ text: String) -> String {
        var output = applyMonthFirstDateOrdinals(text)
        output = applyDayFirstDateOrdinals(output)
        return output
    }

    /// US-style "<Month> <day>": "September 1, 1939" -> "September first,
    /// 1939". The negative lookahead after the day excludes range/slash/
    /// decimal forms ("September 1-3", "9/1", "3.14") so a range endpoint is
    /// never turned into an ordinal; any trailing ", 1939" sits outside the
    /// match and passes through untouched.
    private static func applyMonthFirstDateOrdinals(_ text: String) -> String {
        let pattern = #"\b(\#(dateMonthNames))[ \t]+(\d{1,2})(?![\d./–—-])"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        let nsText = text as NSString
        var result = ""
        var lastEnd = 0
        for match in regex.matches(in: text, range: NSRange(location: 0, length: nsText.length)) {
            let fullRange = match.range
            result += nsText.substring(with: NSRange(location: lastEnd, length: fullRange.location - lastEnd))

            let matchedText = nsText.substring(with: fullRange)
            let month = nsText.substring(with: match.range(at: 1))
            let dayString = nsText.substring(with: match.range(at: 2))
            if let day = Int(dayString), let ordinal = dayOrdinal(day) {
                result += "\(month) \(ordinal)"
            } else {
                result += matchedText
            }
            lastEnd = fullRange.location + fullRange.length
        }
        result += nsText.substring(from: lastEnd)
        return result
    }

    /// International-style "<day> <Month>": "1 September 1939" -> "first
    /// September 1939". The lookbehind keeps a day that's actually part of a
    /// larger number (e.g. a year) from being mistaken for a day-of-month.
    private static func applyDayFirstDateOrdinals(_ text: String) -> String {
        let pattern = #"(?<![\d.])\b(\d{1,2})[ \t]+(\#(dateMonthNames))\b"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        let nsText = text as NSString
        var result = ""
        var lastEnd = 0
        for match in regex.matches(in: text, range: NSRange(location: 0, length: nsText.length)) {
            let fullRange = match.range
            result += nsText.substring(with: NSRange(location: lastEnd, length: fullRange.location - lastEnd))

            let matchedText = nsText.substring(with: fullRange)
            let dayString = nsText.substring(with: match.range(at: 1))
            let month = nsText.substring(with: match.range(at: 2))
            if let day = Int(dayString), let ordinal = dayOrdinal(day) {
                result += "\(ordinal) \(month)"
            } else {
                result += matchedText
            }
            lastEnd = fullRange.location + fullRange.length
        }
        result += nsText.substring(from: lastEnd)
        return result
    }

    /// Maps a day-of-month (1...31) to its ordinal word; nil for anything
    /// outside that range so callers leave 4-digit years and other numbers
    /// untouched.
    private static func dayOrdinal(_ n: Int) -> String? {
        let ordinals: [Int: String] = [
            1: "first", 2: "second", 3: "third", 4: "fourth", 5: "fifth",
            6: "sixth", 7: "seventh", 8: "eighth", 9: "ninth", 10: "tenth",
            11: "eleventh", 12: "twelfth", 13: "thirteenth", 14: "fourteenth", 15: "fifteenth",
            16: "sixteenth", 17: "seventeenth", 18: "eighteenth", 19: "nineteenth", 20: "twentieth",
            21: "twenty-first", 22: "twenty-second", 23: "twenty-third", 24: "twenty-fourth", 25: "twenty-fifth",
            26: "twenty-sixth", 27: "twenty-seventh", 28: "twenty-eighth", 29: "twenty-ninth", 30: "thirtieth",
            31: "thirty-first",
        ]
        return ordinals[n]
    }

    // MARK: - Shared helper

    private static func replace(_ text: String, pattern: String, template: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.stringByReplacingMatches(in: text, range: range, withTemplate: template)
    }
}
