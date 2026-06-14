@testable import AudioAnalysis
import Foundation
import XCTest

/// Track E5d — the Swift RoBERTa BPE tokenizer reproduces the HF tokenization
/// exactly, and the text encoder yields a usable embedding. Skips when the
/// model/tokenizer fixtures are absent.
final class CLAPTextSearchTests: XCTestCase {
    private func requireDir() throws -> URL {
        guard let dir = CLAPModel.resourceDir(),
              FileManager.default.fileExists(atPath: dir.appendingPathComponent("vocab.json").path),
              FileManager.default.fileExists(atPath: dir.appendingPathComponent("golden.json").path) else {
            throw XCTSkip("CLAP tokenizer fixtures not present — skipping")
        }
        return dir
    }

    func testTokenizerMatchesGolden() throws {
        let dir = try requireDir()
        let tok = try XCTUnwrap(RobertaBPETokenizer(dir: dir))

        let gj = try JSONSerialization.jsonObject(
            with: Data(contentsOf: dir.appendingPathComponent("golden.json"))) as? [String: Any]
        let text = try XCTUnwrap(gj?["text"] as? [String: Any])
        let phrase = try XCTUnwrap(text["phrase"] as? String)
        let goldenIds = try XCTUnwrap(text["ids"] as? [Int]).map { Int32($0) }
        let goldenMask = try XCTUnwrap(text["mask"] as? [Int]).map { Int32($0) }
        let maxLen = (text["max_length"] as? Int) ?? 64

        let (ids, mask) = tok.encode(phrase, maxLength: maxLen)
        XCTAssertEqual(ids, goldenIds, "token ids must match the HF RobertaTokenizer exactly")
        XCTAssertEqual(mask, goldenMask, "attention mask must match")
    }

    func testTextEmbeddingIsUsable() throws {
        _ = try requireDir()
        guard let model = CLAPModel.load(), model.canEmbedText else { throw XCTSkip("model not loadable") }
        let emb = try model.textEmbedding("a dreamy ambient piano piece")
        XCTAssertEqual(emb.count, CLAPModel.embeddingDim)
        XCTAssertTrue(emb.allSatisfy { $0.isFinite })
        // L2-normalized → unit norm.
        let norm = emb.reduce(Float(0)) { $0 + $1 * $1 }.squareRoot()
        XCTAssertEqual(norm, 1.0, accuracy: 1e-3)
    }
}
