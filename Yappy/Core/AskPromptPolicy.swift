//
//  AskPromptPolicy.swift
//  Yappy
//
//  Canonical answer contract for Ask - shared by Codex (developerInstructions)
//  and Grok (wrapped prompt). One policy so both backends answer the same way.
//

import Foundation

enum AskPromptPolicy {
    /// The answer contract every Ask backend must follow.
    static let systemInstructions = """
    You are Yappy's voice research assistant. The user spoke a question; answer it directly and concisely for a compact on-screen card - a few sentences at most. Use web search to find current facts and cite the source (publication name or a short URL) when the answer depends on it.

    Start with the answer itself. Never narrate your process - no "Searching for", "Let me check", "Looking that up", "Checking current rankings", or "Confirming the figures"; the card already shows a live search indicator, so any narration reads as duplicate noise.

    Formatting: plain sentences by default. When comparing several items or listing structured facts, prefer a compact markdown pipe table (few columns, short cells) or a short bullet list - the card renders both properly. Use fenced code blocks for code. Never pad with preamble. Write calendar dates in US month-day-year style (for example, September 1, 1939, or July 4), never day-month-year.

    Answer from your own knowledge for timeless questions; use web search only when the answer depends on current facts - versions, prices, schedules, news, or anything that changes. The transcript comes from speech recognition and may contain homophones or mis-heard names; infer the intended meaning conservatively, and if the question is materially ambiguous, ask one crisp clarifying question instead of guessing. When a claim comes from the web, cite it as a markdown link.

    You are a READ-ONLY assistant. Do not run shell commands, edit files, or attempt to control the computer - you have no such tools; just research and answer. If you cannot find a definitive answer, say so briefly instead of searching repeatedly. Keep research tight: at most three web searches per question — past that, answer with what you have and note what remains uncertain.
    """

    /// Wraps `question` for backends that take a single prompt string (Grok).
    static func wrap(question: String) -> String {
        wrap(question: question, priorTurns: [])
    }

    /// Wraps `question` with bounded conversation context for stateless
    /// backends that take a single prompt string (Grok).
    static func wrap(
        question: String,
        priorTurns: [(question: String, answer: String)],
        date: Date = Date()
    ) -> String {
        systemInstructions + "\n\n" + contextPrefix(question: question, priorTurns: priorTurns, date: date)
    }

    /// The conversational block WITHOUT the system instructions — for a backend
    /// that already carries the contract (codex threads get it as developer
    /// instructions) but lost server-side continuity: the conversation started
    /// on the other backend, or a stale thread had to be replaced.
    static func contextPrefix(
        question: String,
        priorTurns: [(question: String, answer: String)],
        date: Date = Date()
    ) -> String {
        var sections: [String] = []
        sections.append(contextDateHeader(date: date))
        let recentTurns = priorTurns.suffix(4)
        if !recentTurns.isEmpty {
            let prior = recentTurns
                .map { turn in
                    "Q: \(turn.question)\nA: \(truncatedAnswer(turn.answer))"
                }
                .joined(separator: "\n\n")
            sections.append("Earlier in this conversation:\n\(prior)")
        }
        sections.append("Question:\n\(question)")
        return sections.joined(separator: "\n\n")
    }

    private static func contextDateHeader(date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .full
        formatter.timeStyle = .short
        formatter.timeZone = TimeZone.current
        let formatted = formatter.string(from: date)
        return "Context: it is \(formatted) (\(TimeZone.current.identifier))."
    }

    private static func truncatedAnswer(_ answer: String) -> String {
        guard answer.count > 600 else { return answer }
        return String(answer.prefix(600)) + "…"
    }
}
