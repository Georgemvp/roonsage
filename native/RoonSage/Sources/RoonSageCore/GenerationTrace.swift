import Foundation

/// A structured, human-readable trace of ONE AI playlist generation: every
/// stage's inputs, the intermediate pool sizes, the engine's decisions, the
/// LLM's picks and the final result — so a "hit or miss" run can be inspected
/// end-to-end. Emitted to the log (category `.llm`, shareable via
/// `LogConsoleView`) and attached to `GenerationResult.trace` so the app can
/// show a "Diagnostiek" panel right under the result.
///
/// Purely diagnostic: nothing here feeds back into the pipeline, so recording
/// can never change the generated playlist. Mutated only on the main actor (the
/// whole generation pipeline is MainActor-isolated); it is never handed to a
/// background task, so a plain reference type is safe.
public final class GenerationTrace {
    private var sections: [(title: String, lines: [String])] = []

    public init() {}

    /// Start a new section; subsequent `line`s attach to it.
    func section(_ title: String) { sections.append((title, [])) }

    /// Add a detail line to the current section (opens a headless one if needed).
    func line(_ text: String) {
        if sections.isEmpty { sections.append(("", [])) }
        sections[sections.count - 1].lines.append(text)
    }

    /// Add a `key: value` detail line.
    func kv(_ key: String, _ value: String) { line("\(key): \(value)") }

    /// Add a `key: value` line only when `value` is non-empty (skip noise).
    func kvIf(_ key: String, _ value: String) { if !value.isEmpty { kv(key, value) } }

    /// A comma-joined list, capped with an overflow marker; "—" when empty.
    static func list(_ items: [String], cap: Int = 12) -> String {
        guard !items.isEmpty else { return "—" }
        let shown = items.prefix(cap).joined(separator: ", ")
        return items.count > cap ? "\(shown) … (+\(items.count - cap))" : shown
    }

    /// Render the whole trace as a boxed, indented text block for the log/UI.
    public func render() -> String {
        var out = ["╭── AI-playlist generatie ──────────"]
        for s in sections {
            if !s.title.isEmpty { out.append("├─ \(s.title)") }
            for l in s.lines { out.append("│   \(l)") }
        }
        out.append("╰───────────────────────────────────")
        return out.joined(separator: "\n")
    }
}
