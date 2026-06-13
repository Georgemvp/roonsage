/// Camelot-wheel mapping (pitch class → Camelot code) + note names.
public enum Camelot {
    public static let noteNames = ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"]

    // Indexed by pitch class (0 = C).
    private static let majorCodes = ["8B", "3B", "10B", "5B", "12B", "7B", "2B", "9B", "4B", "11B", "6B", "1B"]
    private static let minorCodes = ["5A", "12A", "7A", "2A", "9A", "4A", "11A", "6A", "1A", "8A", "3A", "10A"]

    public static func code(rootIndex: Int, mode: String) -> String {
        let r = ((rootIndex % 12) + 12) % 12
        return mode == "minor" ? minorCodes[r] : majorCodes[r]
    }

    public static func note(rootIndex: Int) -> String {
        noteNames[((rootIndex % 12) + 12) % 12]
    }

    /// Harmonically-compatible Camelot codes for DJ mixing: same code, same
    /// number other letter, and ±1 on the wheel (same letter).
    public static func compatible(_ code: String) -> Set<String> {
        guard let last = code.last, last == "A" || last == "B",
              let num = Int(code.dropLast()), (1...12).contains(num) else { return [] }
        let letter = String(last)
        let other = letter == "A" ? "B" : "A"
        let plus1 = (num % 12) + 1
        let minus1 = ((num - 2 + 12) % 12) + 1
        return ["\(num)\(letter)", "\(num)\(other)", "\(plus1)\(letter)", "\(minus1)\(letter)"]
    }
}
