import CoreGraphics

/// Uniform-grid spatial index over the unit square [0,1]×[0,1]. Buckets 2D points
/// into an n×n grid so a proximity query inspects only the cells overlapping the
/// query box instead of scanning every point — turning MusicMapView's per-tap
/// nearest-point search from O(points) into O(1) amortized on a 50k-point map.
///
/// Points outside the unit square are clamped into the edge cells. Pure and
/// `Sendable`; the caller owns the point→payload mapping (buckets store the input
/// index, so `candidates` returns indices into the array that built the grid).
public struct SpatialGrid: Sendable {
    public let resolution: Int
    private let buckets: [[Int]]

    public init(points: [CGPoint], resolution: Int = 64) {
        let n = max(1, resolution)
        self.resolution = n
        var b = [[Int]](repeating: [], count: n * n)
        for (i, p) in points.enumerated() {
            b[Self.cell(p.y, n) * n + Self.cell(p.x, n)].append(i)
        }
        buckets = b
    }

    /// Clamp a unit-square coordinate to a valid cell index [0, n-1].
    private static func cell(_ v: CGFloat, _ n: Int) -> Int {
        min(n - 1, max(0, Int(v * CGFloat(n))))
    }

    /// Indices of every point in the cells overlapping the axis-aligned box
    /// centred on (x, y) with half-extents (rx, ry), all in unit-square
    /// coordinates. A superset of the points actually inside that box — the caller
    /// applies the exact distance test — but it never misses a point inside it, so
    /// a nearest-within-box search over the result is exact.
    public func candidates(x: CGFloat, y: CGFloat, rx: CGFloat, ry: CGFloat) -> [Int] {
        let n = resolution
        let x0 = Self.cell(x - rx, n), x1 = Self.cell(x + rx, n)
        let y0 = Self.cell(y - ry, n), y1 = Self.cell(y + ry, n)
        var out: [Int] = []
        for cy in y0...y1 {
            for cx in x0...x1 {
                out.append(contentsOf: buckets[cy * n + cx])
            }
        }
        return out
    }
}
