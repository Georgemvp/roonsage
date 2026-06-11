import Foundation

/// Fuzzy title matching for the analyzer↔library feature join's *fallback* pass.
///
/// Exact `TrackIdentity.matchKey` equality handles the common case; this catches
/// the residual where Roon and the file tag describe the same recording with
/// different words — chiefly **classical truncation** ("Symphony No. 5" vs
/// "Symphony No. 5 in C Minor, Op. 67") and minor extra qualifiers. It is only
/// ever applied *within the same primary artist*, so the looseness is bounded.
public enum FuzzyMatch {

    /// Normalised title tokens (cleaned of prefix/feat/remaster first).
    public static func tokens(_ title: String?) -> Set<String> {
        Set(TrackIdentity.normalise(TrackIdentity.cleanTitle(title))
            .split(separator: " ").map(String.init))
    }

    /// Containment score in [0,1]: |A∩B| / min(|A|,|B|).
    ///
    /// 1.0 when the shorter title's words are a subset of the longer's — exactly
    /// the classical-truncation case. Single-token titles ("Lithium") must match
    /// exactly, otherwise a lone common word ("intro", "untitled") would over-match.
    public static func score(_ a: String?, _ b: String?) -> Double {
        score(tokens(a), tokens(b))
    }

    public static func score(_ ta: Set<String>, _ tb: Set<String>) -> Double {
        guard !ta.isEmpty, !tb.isEmpty else { return 0 }
        let smaller = min(ta.count, tb.count)
        if smaller < 2 { return ta == tb ? 1 : 0 }
        return Double(ta.intersection(tb).count) / Double(smaller)
    }
}
