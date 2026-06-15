//
//  Mode.swift
//  Yappy
//

import Foundation

/// A named dictation profile that bundles tone, cleanup, and formatting
/// preferences. The built-in `.auto` mode defers entirely to global Settings and
/// per-app tone — so with only Auto active, behavior is identical to having no
/// modes at all. Custom modes override those choices and can auto-activate for a
/// category of app.
struct Mode: Identifiable, Codable, Equatable {
    let id: UUID
    var name: String
    var symbolName: String
    var tone: ToneStyle
    /// nil = inherit the global `cleanupEnabled` setting.
    var cleanupEnabledOverride: Bool?
    var numberFormatting: Bool
    var numberedLists: Bool
    var fillerRemoval: Bool
    var spokenCommands: Bool
    var spokenPunctuation: Bool
    var extraDictionaryTerms: [String]
    var autoTriggerCategory: AppCategory?
    var isAuto: Bool

    init(
        id: UUID = UUID(),
        name: String,
        symbolName: String = "slider.horizontal.3",
        tone: ToneStyle = .formal,
        cleanupEnabledOverride: Bool? = nil,
        numberFormatting: Bool = true,
        numberedLists: Bool = true,
        fillerRemoval: Bool = true,
        spokenCommands: Bool = true,
        spokenPunctuation: Bool = true,
        extraDictionaryTerms: [String] = [],
        autoTriggerCategory: AppCategory? = nil,
        isAuto: Bool = false
    ) {
        self.id = id
        self.name = name
        self.symbolName = symbolName
        self.tone = tone
        self.cleanupEnabledOverride = cleanupEnabledOverride
        self.numberFormatting = numberFormatting
        self.numberedLists = numberedLists
        self.fillerRemoval = fillerRemoval
        self.spokenCommands = spokenCommands
        self.spokenPunctuation = spokenPunctuation
        self.extraDictionaryTerms = extraDictionaryTerms
        self.autoTriggerCategory = autoTriggerCategory
        self.isAuto = isAuto
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, symbolName, tone, cleanupEnabledOverride
        case numberFormatting, numberedLists, fillerRemoval, spokenCommands, spokenPunctuation
        case extraDictionaryTerms, autoTriggerCategory, isAuto
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decode(String.self, forKey: .name)
        symbolName = try c.decodeIfPresent(String.self, forKey: .symbolName) ?? "slider.horizontal.3"
        tone = try c.decodeIfPresent(ToneStyle.self, forKey: .tone) ?? .formal
        cleanupEnabledOverride = try c.decodeIfPresent(Bool.self, forKey: .cleanupEnabledOverride)
        numberFormatting = try c.decodeIfPresent(Bool.self, forKey: .numberFormatting) ?? true
        numberedLists = try c.decodeIfPresent(Bool.self, forKey: .numberedLists) ?? true
        fillerRemoval = try c.decodeIfPresent(Bool.self, forKey: .fillerRemoval) ?? true
        spokenCommands = try c.decodeIfPresent(Bool.self, forKey: .spokenCommands) ?? true
        spokenPunctuation = try c.decodeIfPresent(Bool.self, forKey: .spokenPunctuation) ?? true
        extraDictionaryTerms = try c.decodeIfPresent([String].self, forKey: .extraDictionaryTerms) ?? []
        autoTriggerCategory = try c.decodeIfPresent(AppCategory.self, forKey: .autoTriggerCategory)
        isAuto = try c.decodeIfPresent(Bool.self, forKey: .isAuto) ?? false
    }

    /// Stable id for the built-in Auto mode so it survives reloads.
    static let autoID = UUID(uuidString: "00000000-0000-0000-0000-0000000000A0")!

    /// The built-in mode: defers to global Settings + per-app tone.
    static let auto = Mode(id: autoID, name: "Auto", symbolName: "wand.and.stars", isAuto: true)
}

/// Picks the mode in effect for a dictation, given the active selection and the
/// frontmost app's category. Pure and unit-tested.
enum ModeResolver {
    static func resolve(activeID: UUID?, in modes: [Mode], forCategory category: AppCategory) -> Mode {
        // An explicitly-selected custom mode always wins.
        if let activeID, let active = modes.first(where: { $0.id == activeID }), !active.isAuto {
            return active
        }
        // Auto (or an unknown selection): fall back to an auto-trigger match for
        // this app category, otherwise the Auto mode itself.
        if let match = modes.first(where: { !$0.isAuto && $0.autoTriggerCategory == category }) {
            return match
        }
        return modes.first(where: { $0.isAuto }) ?? .auto
    }
}
