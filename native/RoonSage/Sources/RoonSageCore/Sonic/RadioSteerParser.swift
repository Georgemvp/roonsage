import Foundation

/// A parsed natural-language steer for the running station. For now the single
/// clear, safe axis is the adventurousness dial — "verras me / avontuurlijker"
/// pushes it up, "veiliger / vertrouwder" pulls it down — since that's the one
/// knob `RadioEngine` actually reads. Energy/mood phrases return nil (no steer)
/// rather than being mis-mapped onto adventurousness.
public struct RadioSteer: Sendable, Equatable {
    /// Signed change to apply to the 0…1 adventurousness dial.
    public var adventurousnessDelta: Double
}

/// Pure, vocabulary-based parser (Dutch + English). Deterministic — unit-tested.
public enum RadioSteerParser {
    static let step = 0.2
    static let strongStep = 0.35

    /// "more adventurous / surprise me" cues.
    private static let upWords = [
        "avontuurlijk", "verras", "gekker", "wilder", "spannend", "meer ontdekken",
        "adventurous", "surprise", "experimenteler", "diverser",
    ]
    /// Explicitly "safer / more familiar" cues (non-negated).
    private static let safeWords = [
        "veiliger", "vertrouwder", "bekender", "rustiger aan", "safer", "familiar",
    ]
    /// Negation / reduction cues that flip an up-word into a down.
    private static let negations = ["niet", "minder", "less", "geen", "zonder"]
    /// Intensifiers that make the step larger.
    private static let intensifiers = ["veel", "heel", "way", "much", "flink"]

    public static func parse(_ phrase: String) -> RadioSteer? {
        let p = phrase.lowercased()
        guard !p.isEmpty else { return nil }
        let mag = intensifiers.contains(where: { p.contains($0) }) ? strongStep : step

        if safeWords.contains(where: { p.contains($0) }) {
            return RadioSteer(adventurousnessDelta: -mag)
        }
        if upWords.contains(where: { p.contains($0) }) {
            let negated = negations.contains { p.contains($0) }
            return RadioSteer(adventurousnessDelta: negated ? -mag : mag)
        }
        return nil
    }
}
