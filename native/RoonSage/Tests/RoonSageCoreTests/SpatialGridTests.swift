import CoreGraphics
import XCTest
@testable import RoonSageCore

final class SpatialGridTests: XCTestCase {

    /// Brute-force nearest index within a screen-space radius, the O(n) baseline
    /// the grid must reproduce exactly.
    private func brute(_ pts: [CGPoint], to q: CGPoint) -> Int? {
        var best: Int?; var bestD = CGFloat.greatestFiniteMagnitude
        for (i, p) in pts.enumerated() {
            let d = (p.x - q.x) * (p.x - q.x) + (p.y - q.y) * (p.y - q.y)
            if d < bestD { bestD = d; best = i }
        }
        return best
    }

    func testCandidatesContainTheTrueNearest() {
        // A deterministic spread across the unit square (no RNG — reproducible).
        var pts: [CGPoint] = []
        for i in 0..<400 {
            pts.append(CGPoint(x: Double(i % 20) / 20.0 + 0.01,
                               y: Double(i / 20) / 20.0 + 0.01))
        }
        let grid = SpatialGrid(points: pts, resolution: 16)

        // For a set of queries, the grid's candidate set must include the true
        // nearest point, so a distance test over candidates matches brute force.
        for q in [CGPoint(x: 0.12, y: 0.34), CGPoint(x: 0.0, y: 0.0),
                  CGPoint(x: 0.99, y: 0.98), CGPoint(x: 0.5, y: 0.5)] {
            let truth = brute(pts, to: q)!
            let cand = grid.candidates(x: q.x, y: q.y, rx: 0.1, ry: 0.1)
            let best = cand.min { l, r in
                let dl = (pts[l].x - q.x) * (pts[l].x - q.x) + (pts[l].y - q.y) * (pts[l].y - q.y)
                let dr = (pts[r].x - q.x) * (pts[r].x - q.x) + (pts[r].y - q.y) * (pts[r].y - q.y)
                return dl < dr
            }
            XCTAssertEqual(best, truth, "grid nearest must match brute force at \(q)")
        }
    }

    func testEveryPointBucketedExactlyOnce() {
        let pts = (0..<100).map { CGPoint(x: Double($0) / 100.0, y: Double($0 % 10) / 10.0) }
        let grid = SpatialGrid(points: pts, resolution: 8)
        // A query covering the whole square returns every index (each bucketed once).
        let all = grid.candidates(x: 0.5, y: 0.5, rx: 1.0, ry: 1.0).sorted()
        XCTAssertEqual(all, Array(0..<100))
    }

    func testOutOfRangePointsClampToEdgeCells() {
        // Points outside [0,1] must still be findable (clamped into edge cells),
        // never crash or vanish.
        let pts = [CGPoint(x: -5, y: -5), CGPoint(x: 9, y: 9), CGPoint(x: 0.5, y: 0.5)]
        let grid = SpatialGrid(points: pts, resolution: 4)
        XCTAssertTrue(grid.candidates(x: 0, y: 0, rx: 0.3, ry: 0.3).contains(0))
        XCTAssertTrue(grid.candidates(x: 1, y: 1, rx: 0.3, ry: 0.3).contains(1))
    }
}
