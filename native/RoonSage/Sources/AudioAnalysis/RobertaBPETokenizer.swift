import Foundation

/// Byte-level BPE tokenizer matching CLAP's `RobertaTokenizer` (GPT-2 style),
/// so the analyzer can turn a text query into the exact `input_ids` the Core ML
/// text encoder expects (Track E5d, text search). Lives analyzer-side only;
/// thin clients hit the analyzer's /text-embed endpoint.
public final class RobertaBPETokenizer: @unchecked Sendable {
    private let vocab: [String: Int]
    private let bpeRanks: [String: Int]    // "first second" -> rank
    private let byteEncoder: [UInt8: Character]
    private let pattern: NSRegularExpression

    public let bosId: Int32 = 0    // <s>
    public let padId: Int32 = 1    // <pad>
    public let eosId: Int32 = 2    // </s>
    public let unkId: Int32 = 3    // <unk>

    public init?(dir: URL) {
        let vurl = dir.appendingPathComponent("vocab.json")
        let murl = dir.appendingPathComponent("merges.txt")
        guard let vdata = try? Data(contentsOf: vurl),
              let vobj = try? JSONSerialization.jsonObject(with: vdata) as? [String: Int],
              let mstr = try? String(contentsOf: murl, encoding: .utf8) else { return nil }
        vocab = vobj

        var ranks: [String: Int] = [:]
        var rank = 0
        for line in mstr.split(separator: "\n", omittingEmptySubsequences: true) {
            if line.hasPrefix("#") { continue }
            let parts = line.split(separator: " ")
            guard parts.count == 2 else { continue }
            ranks["\(parts[0]) \(parts[1])"] = rank
            rank += 1
        }
        bpeRanks = ranks
        byteEncoder = Self.byteToUnicode()

        // GPT-2 pre-tokenization pattern.
        let pat = "'s|'t|'re|'ve|'m|'ll|'d| ?\\p{L}+| ?\\p{N}+| ?[^\\s\\p{L}\\p{N}]+|\\s+(?!\\S)|\\s+"
        guard let re = try? NSRegularExpression(pattern: pat) else { return nil }
        pattern = re
    }

    /// Encode to fixed-length `input_ids` + `attention_mask` (bos + content +
    /// eos, padded to `maxLength`), matching the HF processor.
    public func encode(_ text: String, maxLength: Int = 64) -> (ids: [Int32], mask: [Int32]) {
        var content: [Int32] = []
        let ns = text as NSString
        for m in pattern.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            let piece = ns.substring(with: m.range)
            // byte-level encode each UTF-8 byte to its mapped unicode char
            var mapped = ""
            for b in Array(piece.utf8) { mapped.append(byteEncoder[b] ?? "?") }
            for symbol in bpe(mapped) {
                content.append(Int32(vocab[symbol] ?? Int(unkId)))
            }
        }
        // bos + content (truncated) + eos, then pad.
        let room = max(0, maxLength - 2)
        if content.count > room { content = Array(content.prefix(room)) }
        var ids: [Int32] = [bosId] + content + [eosId]
        var mask = [Int32](repeating: 1, count: ids.count)
        if ids.count < maxLength {
            let pad = maxLength - ids.count
            ids.append(contentsOf: repeatElement(padId, count: pad))
            mask.append(contentsOf: repeatElement(0, count: pad))
        }
        return (ids, mask)
    }

    // MARK: - BPE

    private func bpe(_ token: String) -> [String] {
        var word = token.map { String($0) }
        guard word.count > 1 else { return word }
        while true {
            // find the adjacent pair with the lowest merge rank
            var bestRank = Int.max
            var bestIdx = -1
            for i in 0..<(word.count - 1) {
                if let r = bpeRanks["\(word[i]) \(word[i + 1])"], r < bestRank {
                    bestRank = r; bestIdx = i
                }
            }
            if bestIdx < 0 { break }
            word.replaceSubrange(bestIdx...bestIdx + 1, with: [word[bestIdx] + word[bestIdx + 1]])
            if word.count == 1 { break }
        }
        return word
    }

    /// GPT-2 byte→unicode table (maps every byte to a printable char).
    static func byteToUnicode() -> [UInt8: Character] {
        var bs = Array(33...126) + Array(161...172) + Array(174...255)
        var cs = bs
        var n = 0
        for b in 0...255 where !bs.contains(b) {
            bs.append(b); cs.append(256 + n); n += 1
        }
        var map = [UInt8: Character](minimumCapacity: 256)
        for (b, c) in zip(bs, cs) {
            map[UInt8(b)] = Character(UnicodeScalar(c)!)
        }
        return map
    }
}
