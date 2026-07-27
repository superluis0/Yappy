//
//  SpokenNumberFormatter.swift
//  Yappy
//

import Foundation

/// Converts spoken-out numbers into written form — the inverse text
/// normalization that the Parakeet model does not perform itself:
///
///   "eleven point six point zero"     → "11.6.0"
///   "twenty three"                    → "23"
///   "twenty third"                    → "23rd"
///   "fifty percent"                   → "50%"
///   "twenty dollars and fifty cents"  → "$20.50"
///   "three thirty pm"                 → "3:30 PM"
///   "twenty twenty six"               → "2026"
///   "five five five one two one two"  → "5551212"
///
/// Deterministic and fully local (no LLM). Conservative by design: it only
/// rewrites maximal runs of number words, leaves all other text untouched, and
/// declines ambiguous cases (a bare scale word like "million", a standalone
/// "second") rather than guessing.
enum SpokenNumberFormatter {

    private typealias Token = TranscriptTokenizer.Token

    // MARK: - Public

    static func format(_ text: String) -> String {
        // Repair the ASR's digit-time misrendering before anything else: Parakeet
        // sometimes emits a spoken clock time with a period instead of a colon
        // ("7. 30 A.M." / "7.30 AM"), and the downstream model cleanup only
        // sometimes fixes it. This must run before the number-word guard below —
        // the misrendered text contains digits, not number words.
        let text = repairDigitTimes(text)

        let tokens = TranscriptTokenizer.tokenize(text)
        guard tokens.contains(where: {
            if case .word(let w) = $0 { return isRunStartWord(w.lowercased()) }
            return false
        }) else {
            return text
        }

        var output = ""
        var i = 0
        while i < tokens.count {
            guard case .word(let word) = tokens[i], isRunStartWord(word.lowercased()) else {
                output += tokens[i].text
                i += 1
                continue
            }

            var runIndices = collectRun(tokens, startingAt: i)

            // A trailing "point" is the literal word, not a decimal separator.
            while let last = runIndices.last,
                  case .word(let w) = tokens[last], w.lowercased() == "point" {
                runIndices.removeLast()
            }

            let words = runIndices.map { idx -> String in
                if case .word(let w) = tokens[idx] { return w.lowercased() }
                return ""
            }
            let lastIdx = runIndices.last ?? i

            if let converted = convertRun(words) {
                let (text, consumedThrough) = applySuffixes(to: converted, tokens: tokens, runEnd: lastIdx)
                // Prose guard: a lone small number with nothing quantitative
                // around it reads better spelled out ("one of these days", not
                // "1 of these days"). Only reachable when no suffix anchored the
                // run — money, percentages and clock times keep their digits.
                if consumedThrough == lastIdx,
                   !isDottedMeridiem(tokens, afterRunEnd: lastIdx),
                   staysSpelledOut(kind: converted.kind, words: words,
                                   tokens: tokens, runStart: i, runEnd: lastIdx) {
                    for idx in i...lastIdx { output += tokens[idx].text }
                    i = lastIdx + 1
                    continue
                }
                output += text
                i = consumedThrough + 1
            } else {
                // Emit the original substring (words + their joining spaces) untouched.
                for idx in i...lastIdx { output += tokens[idx].text }
                i = lastIdx + 1
            }
        }
        return output
    }

    // MARK: - Digit-time repair

    /// "7. 30" or "7.30" followed by a meridiem → "7:30". Anchored on the
    /// meridiem (mirroring the spoken-time rule below, which is also
    /// meridiem-anchored) so genuine decimals ("7.30 inches") never match;
    /// hour restricted to a valid 12-hour clock reading. The meridiem itself
    /// is left exactly as written.
    private static let digitTimeRegex = try! NSRegularExpression(
        pattern: #"\b(1[0-2]|0?[1-9])\.\s?([0-5][0-9])(?=\s?[AaPp]\.?[Mm]\b)"#
    )

    private static func repairDigitTimes(_ text: String) -> String {
        let range = NSRange(text.startIndex..., in: text)
        guard digitTimeRegex.firstMatch(in: text, range: range) != nil else { return text }
        return digitTimeRegex.stringByReplacingMatches(
            in: text, range: range, withTemplate: "$1:$2")
    }

    // MARK: - Run Collection

    /// Collects a maximal run of number/"point"/ordinal words joined by single
    /// spaces. An ordinal word terminates the run (it can only end a number).
    private static func collectRun(_ tokens: [Token], startingAt start: Int) -> [Int] {
        var indices = [start]
        if case .word(let w) = tokens[start], ordinalValues[w.lowercased()] != nil {
            return indices
        }
        var k = start
        while k + 2 < tokens.count,
              case .gap(let gap) = tokens[k + 1], gap == " ",
              case .word(let next) = tokens[k + 2] {
            let lower = next.lowercased()
            if ordinalValues[lower] != nil {
                indices.append(k + 2)
                break
            }
            guard lower == "point" || isNumberWord(lower) else { break }
            indices.append(k + 2)
            k += 2
        }
        return indices
    }

    // MARK: - Run Conversion

    private enum RunKind {
        case integer(Int)      // single cardinal — eligible for %, currency, time hour
        case pair(Int, Int)    // exactly two cardinals — time candidate ("three thirty")
        case decimal           // "point" form — eligible for %
        case year              // "twenty twenty six"
        case digitRun          // "five five five …"
        case ordinal           // "23rd" — takes no suffixes
        case multiple          // 3+ independent cardinals
    }

    private struct ConvertedRun {
        let rendered: String
        let kind: RunKind
    }

    private static func convertRun(_ words: [String]) -> ConvertedRun? {
        guard !words.isEmpty else { return nil }

        // Ordinal: always the last word of a run.
        if let ordinal = ordinalValues[words.last!] {
            return convertOrdinalRun(prefix: Array(words.dropLast()), ordinal: ordinal)
        }

        // Decimal/version form around "point".
        if words.contains("point") {
            return convertDecimalRun(words)
        }

        // Spoken digit sequences ("five five five …", "zero zero seven").
        if words.count >= 3, words.allSatisfy({ singleDigits[$0] != nil }) {
            let digits = words.map { String(singleDigits[$0]!) }.joined()
            return ConvertedRun(rendered: digits, kind: .digitRun)
        }

        // General: one or more independent strict cardinals.
        var components: [Int] = []
        var i = 0
        while i < words.count {
            guard let (value, consumed) = parseStrictCardinal(words, from: i) else { return nil }
            components.append(value)
            i += consumed
        }

        // Year: "nineteen ninety nine" → 1999, "twenty twenty six" → 2026.
        // Restricted to 19xx/20xx so "eleven twenty" stays "11 20".
        if components.count == 2,
           (components[0] == 19 || components[0] == 20),
           (10...99).contains(components[1]) {
            return ConvertedRun(rendered: String(components[0] * 100 + components[1]), kind: .year)
        }

        let rendered = components.map(String.init).joined(separator: " ")
        switch components.count {
        case 1: return ConvertedRun(rendered: rendered, kind: .integer(components[0]))
        case 2: return ConvertedRun(rendered: rendered, kind: .pair(components[0], components[1]))
        default: return ConvertedRun(rendered: rendered, kind: .multiple)
        }
    }

    private static func convertDecimalRun(_ words: [String]) -> ConvertedRun? {
        var segments: [[String]] = [[]]
        for word in words {
            if word == "point" {
                segments.append([])
            } else {
                segments[segments.count - 1].append(word)
            }
        }

        guard let first = segments.first, !first.isEmpty,
              let (whole, consumed) = parseStrictCardinal(first, from: 0),
              consumed == first.count else {
            return nil
        }

        var result = String(whole)
        for segment in segments.dropFirst() {
            guard !segment.isEmpty, let fractional = parseFractional(segment) else {
                return nil
            }
            result += "." + fractional
        }
        return ConvertedRun(rendered: result, kind: .decimal)
    }

    private static func convertOrdinalRun(prefix: [String], ordinal: Int) -> ConvertedRun? {
        if prefix.isEmpty {
            // Standalone ordinals convert only from "thirteenth" up; below that
            // they're common prose ("wait a second", "third party").
            guard ordinal >= 13 else { return nil }
            return ConvertedRun(rendered: "\(ordinal)\(ordinalSuffix(for: ordinal))", kind: .ordinal)
        }

        guard !prefix.contains("point"),
              let (prefixValue, consumed) = parseStrictCardinal(prefix, from: 0),
              consumed == prefix.count else {
            return nil
        }

        let value: Int
        switch ordinal {
        case 1...9:
            // "twenty third" → 23rd; needs the prefix to end in a plain tens word.
            guard let lastWord = prefix.last, tensWords.contains(lastWord), prefixValue % 10 == 0 else {
                return nil
            }
            value = prefixValue + ordinal
        case 10...90:
            // "one hundred twentieth" → 120th.
            guard prefixValue % 100 == 0, prefixValue > 0 else { return nil }
            value = prefixValue + ordinal
        default:
            // Scale ordinals multiply: "two hundredth" → 200th, "one thousandth" → 1000th.
            value = prefixValue * ordinal
        }
        return ConvertedRun(rendered: "\(value)\(ordinalSuffix(for: value))", kind: .ordinal)
    }

    private static func ordinalSuffix(for value: Int) -> String {
        let lastTwo = value % 100
        if (11...13).contains(lastTwo) { return "th" }
        switch value % 10 {
        case 1: return "st"
        case 2: return "nd"
        case 3: return "rd"
        default: return "th"
        }
    }

    // MARK: - Suffixes (percent, currency, time)

    /// Looks past a converted run for a unit word that merges with the number.
    /// Returns the final text and the index of the last consumed token.
    private static func applySuffixes(
        to run: ConvertedRun, tokens: [Token], runEnd: Int
    ) -> (String, Int) {
        // Percent: "fifty percent" → "50%", "three point five percent" → "3.5%".
        switch run.kind {
        case .integer, .decimal:
            if let (idx, word) = wordAfter(tokens, index: runEnd), word == "percent" {
                return (run.rendered + "%", idx)
            }
        default:
            break
        }

        // Currency: "twenty dollars" → "$20", "+ and fifty cents" → "$20.50".
        if case .integer(let amount) = run.kind,
           let (currencyIdx, word) = wordAfter(tokens, index: runEnd),
           let symbol = currencySymbols[word] {
            if let (cents, centsIdx) = parseCents(tokens, after: currencyIdx) {
                return ("\(symbol)\(amount)." + String(format: "%02d", cents), centsIdx)
            }
            return ("\(symbol)\(run.rendered)", currencyIdx)
        }

        // Time: meridiem-anchored only. "three thirty pm" → "3:30 PM", "three pm" → "3 PM".
        if let timeText = timeForm(of: run.kind) {
            if let (idx, word) = wordAfter(tokens, index: runEnd), word == "am" || word == "pm" {
                return (timeText + " " + word.uppercased(), idx)
            }
            // Dotted meridiem ("p.m.") anchors the time but is left as written,
            // so sentence punctuation around the abbreviation stays intact.
            if isDottedMeridiem(tokens, afterRunEnd: runEnd) {
                return (timeText, runEnd)
            }
        }

        return (run.rendered, runEnd)
    }

    /// "h" or "h:mm" when the run shapes a valid 12-hour clock reading.
    private static func timeForm(of kind: RunKind) -> String? {
        switch kind {
        case .integer(let hour) where (1...12).contains(hour):
            return String(hour)
        case .pair(let hour, let minutes) where (1...12).contains(hour) && (10...59).contains(minutes):
            return "\(hour):" + String(format: "%02d", minutes)
        default:
            return nil
        }
    }

    /// Matches "a.m."/"p.m." token shape: word(a|p) + gap(".") + word(m).
    private static func isDottedMeridiem(_ tokens: [Token], afterRunEnd runEnd: Int) -> Bool {
        guard let (firstIdx, first) = wordAfter(tokens, index: runEnd),
              first == "a" || first == "p",
              firstIdx + 2 < tokens.count,
              case .gap(let dot) = tokens[firstIdx + 1], dot == ".",
              case .word(let m) = tokens[firstIdx + 2], m.lowercased() == "m" else {
            return false
        }
        return true
    }

    /// Matches "[and] <number run> cents" after a currency word. Returns the
    /// cents value and the index of the consumed "cents" token.
    private static func parseCents(_ tokens: [Token], after currencyIdx: Int) -> (Int, Int)? {
        var cursor = currencyIdx
        if let (andIdx, word) = wordAfter(tokens, index: cursor), word == "and" {
            cursor = andIdx
        }

        // Collect the contiguous number words for the cents amount.
        var centsWords: [String] = []
        var lastNumberIdx = cursor
        var probe = cursor
        while let (idx, word) = wordAfter(tokens, index: probe), isNumberWord(word) {
            centsWords.append(word)
            lastNumberIdx = idx
            probe = idx
        }
        guard !centsWords.isEmpty,
              let (value, consumed) = parseStrictCardinal(centsWords, from: 0),
              consumed == centsWords.count,
              (0...99).contains(value),
              let (centsIdx, unit) = wordAfter(tokens, index: lastNumberIdx),
              unit == "cents" || unit == "cent" else {
            return nil
        }
        return (value, centsIdx)
    }

    /// The next word token after `index` when separated by exactly one space.
    private static func wordAfter(_ tokens: [Token], index: Int) -> (Int, String)? {
        guard index + 2 < tokens.count,
              case .gap(let gap) = tokens[index + 1], gap == " ",
              case .word(let word) = tokens[index + 2] else {
            return nil
        }
        return (index + 2, word.lowercased())
    }

    // MARK: - Strict Cardinal Parser

    /// Consumes the longest valid spoken cardinal starting at `start`,
    /// enforcing compound grammar so adjacent independent numbers don't merge
    /// ("eleven twenty" parses as 11, leaving "twenty" for the next parse).
    /// Returns nil when no valid cardinal starts there (e.g. a bare scale word).
    private static func parseStrictCardinal(_ words: [String], from start: Int) -> (value: Int, consumed: Int)? {
        var i = start
        var total = 0              // completed scale groups (thousand/million/billion)
        var hundreds = 0           // completed hundreds within the current group
        var sub = 0                // current sub-hundred accumulator
        var subLastWasTens = false
        var usedHundred = false
        var lastScale = Int.max
        var sawNumberWord = false

        parseLoop: while i < words.count {
            let word = words[i]

            if word == "zero" {
                // "zero" only stands alone as a cardinal.
                if sawNumberWord { break }
                return (0, 1)
            }

            if let value = smallNumbers[word] {
                // NOTE: `break parseLoop` — a bare break here would only exit
                // the switch and silently consume the rejected word.
                switch value {
                case 1...9:
                    guard sub == 0 || subLastWasTens else { break parseLoop }
                    sub += value
                    subLastWasTens = false
                case 10...19:
                    guard sub == 0 else { break parseLoop }
                    sub = value
                    subLastWasTens = false
                default: // 20...90
                    guard sub == 0 else { break parseLoop }
                    sub = value
                    subLastWasTens = true
                }
                sawNumberWord = true
                i += 1
                continue
            }

            if word == "hundred" {
                guard (1...99).contains(sub), !usedHundred, hundreds == 0 else { break }
                hundreds = sub * 100
                sub = 0
                subLastWasTens = false
                usedHundred = true
                i += 1
                continue
            }

            if let scale = scales[word], scale >= 1000 {
                let group = hundreds + sub
                guard group >= 1, scale < lastScale else { break }
                total += group * scale
                hundreds = 0
                sub = 0
                subLastWasTens = false
                usedHundred = false
                lastScale = scale
                i += 1
                continue
            }

            break
        }

        let consumed = i - start
        guard consumed > 0, sawNumberWord else { return nil }
        return (total + hundreds + sub, consumed)
    }

    /// Parses the part after a decimal/version "point". Digits spoken
    /// individually ("one four" → "14", "zero six" → "06") are concatenated to
    /// preserve leading zeros; otherwise the segment is read as one cardinal
    /// ("twenty five" → "25").
    private static func parseFractional(_ words: [String]) -> String? {
        if words.allSatisfy({ singleDigits[$0] != nil }) {
            return words.map { String(singleDigits[$0]!) }.joined()
        }
        guard let (value, consumed) = parseStrictCardinal(words, from: 0),
              consumed == words.count else {
            return nil
        }
        return String(value)
    }

    // MARK: - Vocabulary

    private static let singleDigits: [String: Int] = [
        "zero": 0, "one": 1, "two": 2, "three": 3, "four": 4,
        "five": 5, "six": 6, "seven": 7, "eight": 8, "nine": 9,
    ]

    private static let smallNumbers: [String: Int] = [
        "one": 1, "two": 2, "three": 3, "four": 4, "five": 5,
        "six": 6, "seven": 7, "eight": 8, "nine": 9, "ten": 10,
        "eleven": 11, "twelve": 12, "thirteen": 13, "fourteen": 14, "fifteen": 15,
        "sixteen": 16, "seventeen": 17, "eighteen": 18, "nineteen": 19,
        "twenty": 20, "thirty": 30, "forty": 40, "fifty": 50, "sixty": 60,
        "seventy": 70, "eighty": 80, "ninety": 90,
    ]

    private static let tensWords: Set<String> = [
        "twenty", "thirty", "forty", "fifty", "sixty", "seventy", "eighty", "ninety",
    ]

    private static let scales: [String: Int] = [
        "hundred": 100, "thousand": 1000, "million": 1_000_000, "billion": 1_000_000_000,
    ]

    /// Ordinal word → numeric value. Values 1–12 never convert standalone
    /// (too common as prose); 13+ do.
    private static let ordinalValues: [String: Int] = [
        "first": 1, "second": 2, "third": 3, "fourth": 4, "fifth": 5,
        "sixth": 6, "seventh": 7, "eighth": 8, "ninth": 9, "tenth": 10,
        "eleventh": 11, "twelfth": 12, "thirteenth": 13, "fourteenth": 14,
        "fifteenth": 15, "sixteenth": 16, "seventeenth": 17, "eighteenth": 18,
        "nineteenth": 19, "twentieth": 20, "thirtieth": 30, "fortieth": 40,
        "fiftieth": 50, "sixtieth": 60, "seventieth": 70, "eightieth": 80,
        "ninetieth": 90, "hundredth": 100, "thousandth": 1000, "millionth": 1_000_000,
    ]

    private static let currencySymbols: [String: String] = [
        "dollar": "$", "dollars": "$",
        "euro": "€", "euros": "€",
        "pound": "£", "pounds": "£",
    ]

    private static func isNumberWord(_ word: String) -> Bool {
        word == "zero" || smallNumbers[word] != nil || scales[word] != nil
    }

    /// Words that may begin a run: any number word, or an ordinal (conversion
    /// rules decide later whether a standalone ordinal actually converts).
    // MARK: - Prose guard (small numbers stay spelled out)

    /// Words that make the following number a count or measurement, where
    /// digits read correctly ("3 miles", "5 gigabytes"). Deliberately EXCLUDES
    /// durations (minute/hour/day/week/year): "one day" and "give me one
    /// minute" are ordinary prose, and spelling them matches the same style
    /// rule this guard exists to honor.
    private static let measurementUnits: Set<String> = [
        "mile", "miles", "foot", "feet", "inch", "inches", "yard", "yards",
        "meter", "meters", "metre", "metres", "centimeter", "centimeters",
        "kilometer", "kilometers", "km", "mm", "cm",
        "pound", "pounds", "lb", "lbs", "kilo", "kilos", "kilogram", "kilograms",
        "gram", "grams", "ounce", "ounces", "ton", "tons",
        "gallon", "gallons", "liter", "liters", "litre", "litres",
        "cup", "cups", "tablespoon", "tablespoons", "teaspoon", "teaspoons",
        "degree", "degrees", "volt", "volts", "watt", "watts", "amp", "amps",
        "hertz", "megahertz", "gigahertz", "mph", "kph",
        "byte", "bytes", "kilobyte", "kilobytes", "megabyte", "megabytes",
        "gigabyte", "gigabytes", "terabyte", "terabytes", "pixel", "pixels",
    ]

    /// Words that introduce a numbered thing, where digits are what the user
    /// wants ("step 2", "version 3", "room 4").
    private static let enumerationCues: Set<String> = [
        "number", "step", "chapter", "part", "section", "page", "line", "item",
        "phase", "round", "level", "version", "grade", "room", "apartment",
        "apt", "unit", "figure", "table", "exhibit", "question", "problem",
        "track", "episode", "season", "volume", "floor", "gate", "seat", "row",
        "tier", "rank", "option", "slide", "note", "week",
    ]

    /// True when a converted run should be left as the user spoke it.
    ///
    /// Scope is deliberately narrow: a SINGLE cardinal word for 0-9 with no
    /// quantitative signal beside it. Multi-word numbers ("twenty three"),
    /// anything 10 and over, ordinals, decimals, and every suffixed form
    /// (currency, percent, clock time) are untouched, so lists, times and
    /// measurements keep the digits that make them readable.
    private static func staysSpelledOut(
        kind: RunKind, words: [String], tokens: [Token], runStart: Int, runEnd: Int
    ) -> Bool {
        guard words.count == 1, case .integer(let value) = kind, (0...9).contains(value) else {
            return false
        }
        // A digit already adjacent means the user is enumerating or comparing;
        // mixing "one" with "3" in one breath would look accidental.
        if let (_, next) = wordAfter(tokens, index: runEnd),
           next.first?.isNumber == true { return false }
        if let previous = wordBefore(tokens, index: runStart) {
            if previous.first?.isNumber == true { return false }
            if enumerationCues.contains(previous) { return false }
        }
        if let (_, next) = wordAfter(tokens, index: runEnd),
           measurementUnits.contains(next) { return false }
        return true
    }

    /// The immediately preceding word, lowercased — mirrors `wordAfter`, so a
    /// single space is the only separator that still counts as adjacent
    /// (punctuation between them means it is a different phrase).
    private static func wordBefore(_ tokens: [Token], index: Int) -> String? {
        guard index >= 2,
              case .gap(let gap) = tokens[index - 1], gap == " ",
              case .word(let word) = tokens[index - 2] else {
            return nil
        }
        return word.lowercased()
    }

    private static func isRunStartWord(_ word: String) -> Bool {
        isNumberWord(word) || ordinalValues[word] != nil
    }
}
