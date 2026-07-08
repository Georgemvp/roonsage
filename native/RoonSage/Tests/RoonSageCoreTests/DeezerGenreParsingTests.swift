import AnalyzerCore
import Foundation
import XCTest

/// `DeezerClient.parseGenres` — pure parse of the `/album/{id}` response, no
/// network. Separated so the genre-extraction logic is unit-testable, like
/// `DatasetFetcher.newestRelease`.
final class DeezerGenreParsingTests: XCTestCase {

    private func albumJSON(genreNames: [String]) -> [String: Any] {
        ["genres": ["data": genreNames.map { ["id": 0, "name": $0] }]]
    }

    func testParsesGenreNames() {
        let genres = DeezerClient.parseGenres(fromAlbumJSON: albumJSON(genreNames: ["Electro", "Dance"]))
        XCTAssertEqual(genres, ["Electro", "Dance"])
    }

    func testDropsGenericAllBucket() {
        let genres = DeezerClient.parseGenres(fromAlbumJSON: albumJSON(genreNames: ["All"]))
        XCTAssertNil(genres, "an album with only Deezer's generic 'All' bucket has no real genre signal")
    }

    func testEmptyGenreListYieldsNil() {
        let genres = DeezerClient.parseGenres(fromAlbumJSON: albumJSON(genreNames: []))
        XCTAssertNil(genres)
    }

    func testMissingGenresKeyYieldsNil() {
        XCTAssertNil(DeezerClient.parseGenres(fromAlbumJSON: [:]))
    }
}
