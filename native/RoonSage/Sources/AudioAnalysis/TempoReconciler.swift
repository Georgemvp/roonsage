import Foundation

/// Reconciles a self-analyzed BPM with an external reference (the Deezer dump's
/// `TrackBPM`) to fix the classic octave error: onset-autocorrelation tempo
/// detection routinely locks onto half- or double-time (64 vs 128), which wrecks
/// harmonic/energy sequencing. When our own confidence is low and a reference
/// exists, snap OUR value to whichever octave (½×, 1×, 2×) lands nearest the
/// reference — but never invent a tempo we didn't measure, and never trust a
/// clearly-disagreeing reference (different track entirely).
public enum TempoReconciler {

    /// Confidence at/above which the native BPM is trusted as-is (no correction).
    public static let trustThreshold = 0.5
    /// A corrected octave must land within this fraction of the reference to be
    /// accepted — guards against a mismatched reference row snapping us to noise.
    public static let acceptTolerance = 0.06   // ±6 %

    /// Returns the octave of `nativeBPM` (½×, 1× or 2×) closest to `reference`,
    /// or the untouched `nativeBPM` when no correction is warranted:
    ///   - confidence ≥ trustThreshold  → keep native (we already trust it)
    ///   - reference missing / ≤ 0       → keep native (nothing to compare to)
    ///   - best octave still off by > acceptTolerance → keep native (bad reference)
    public static func reconcile(nativeBPM: Double, confidence: Double, reference: Double?) -> Double {
        guard nativeBPM > 0 else { return nativeBPM }
        guard confidence < trustThreshold else { return nativeBPM }
        guard let reference, reference > 0 else { return nativeBPM }

        let candidates = [nativeBPM / 2.0, nativeBPM, nativeBPM * 2.0]
        let best = candidates.min { abs($0 - reference) < abs($1 - reference) } ?? nativeBPM
        // Only accept if the chosen octave genuinely agrees with the reference.
        guard abs(best - reference) / reference <= acceptTolerance else { return nativeBPM }
        return best
    }
}
