@testable import RoonSageCore
import XCTest

/// Track E5d — PCA-2D projection separates clusters that are far apart in the
/// high-dimensional embedding space.
final class PCAProjectorTests: XCTestCase {
    func testTwoClustersSeparateOnPrincipalAxis() {
        let dim = 6
        let perCluster = 12
        var flat: [Float] = []
        // Cluster A centered at +3 on dim0, cluster B at −3 — deterministic jitter.
        for i in 0..<perCluster {
            var v = [Float](repeating: 0, count: dim)
            v[0] = 3 + Float((i % 5)) * 0.02
            v[1] = Float((i * 3) % 7) * 0.01
            flat.append(contentsOf: v)
        }
        for i in 0..<perCluster {
            var v = [Float](repeating: 0, count: dim)
            v[0] = -3 - Float((i % 5)) * 0.02
            v[1] = Float((i * 3) % 7) * 0.01
            flat.append(contentsOf: v)
        }
        let n = perCluster * 2
        let pts = PCAProjector.project(flat: flat, n: n, dim: dim)
        XCTAssertEqual(pts.count, n)

        let avgA = pts[0..<perCluster].map { $0.x }.reduce(0, +) / Float(perCluster)
        let avgB = pts[perCluster..<n].map { $0.x }.reduce(0, +) / Float(perCluster)
        XCTAssertGreaterThan(abs(avgA - avgB), 0.5, "clusters should land on opposite ends of PC1")
        // All points normalized to [0,1].
        XCTAssertTrue(pts.allSatisfy { $0.x >= -0.001 && $0.x <= 1.001 && $0.y >= -0.001 && $0.y <= 1.001 })
    }

    func testTooFewPointsReturnsEmpty() {
        XCTAssertTrue(PCAProjector.project(flat: [1, 2, 3, 4], n: 2, dim: 2).isEmpty)
    }
}
