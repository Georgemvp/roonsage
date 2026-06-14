import Accelerate
import Foundation

/// 2D PCA projection of CLAP embeddings for the Music Map (Track E5d).
///
/// Finds the top-2 principal components by power iteration on the *implicit*
/// covariance: Cv = Xcᵀ(Xc·v), so we never materialize the 512×512 covariance
/// and avoid LAPACK (and its deprecation warnings) entirely. Two `vDSP_mmul`
/// matrix-vector products per iteration; deterministic init (no RNG).
public enum PCAProjector {

    public struct Point: Sendable { public let x: Float; public let y: Float }

    /// Project `n` row-major vectors of length `dim` to normalized [0,1]² points.
    /// Returns [] if there isn't enough data to define two axes.
    public static func project(flat X: [Float], n: Int, dim: Int, iterations: Int = 80) -> [Point] {
        guard n >= 3, dim >= 2, X.count == n * dim else { return [] }

        // Column means → center the data.
        let ones = [Float](repeating: 1, count: n)
        var mean = [Float](repeating: 0, count: dim)
        vDSP_mmul(ones, 1, X, 1, &mean, 1, 1, vDSP_Length(dim), vDSP_Length(n))
        var invN = 1 / Float(n)
        vDSP_vsmul(mean, 1, &invN, &mean, 1, vDSP_Length(dim))

        var xc = X
        for r in 0..<n {
            for c in 0..<dim { xc[r * dim + c] -= mean[c] }
        }

        // Cv = Xcᵀ (Xc v): two mat-vecs, no explicit covariance.
        func covMul(_ v: [Float]) -> [Float] {
            var u = [Float](repeating: 0, count: n)
            vDSP_mmul(xc, 1, v, 1, &u, 1, vDSP_Length(n), 1, vDSP_Length(dim))
            var w = [Float](repeating: 0, count: dim)
            vDSP_mmul(u, 1, xc, 1, &w, 1, 1, vDSP_Length(dim), vDSP_Length(n))
            return w
        }
        func dot(_ a: [Float], _ b: [Float]) -> Float {
            var r: Float = 0; vDSP_dotpr(a, 1, b, 1, &r, vDSP_Length(min(a.count, b.count))); return r
        }

        // PC1: power iteration from the first centered row.
        var v1 = VectorIndex.normalized(Array(xc[0..<dim]))
        for _ in 0..<iterations { v1 = VectorIndex.normalized(covMul(v1)) }

        // PC2: power iteration deflated against v1 each step.
        var v2 = VectorIndex.normalized(Array(xc[dim..<2 * dim]))
        for _ in 0..<iterations {
            var w = covMul(v2)
            let proj = dot(v1, w)
            for i in 0..<dim { w[i] -= proj * v1[i] }
            v2 = VectorIndex.normalized(w)
        }

        // Project: score = Xc · vk.
        var sx = [Float](repeating: 0, count: n)
        var sy = [Float](repeating: 0, count: n)
        vDSP_mmul(xc, 1, v1, 1, &sx, 1, vDSP_Length(n), 1, vDSP_Length(dim))
        vDSP_mmul(xc, 1, v2, 1, &sy, 1, vDSP_Length(n), 1, vDSP_Length(dim))

        normalize01(&sx)
        normalize01(&sy)
        return (0..<n).map { Point(x: sx[$0], y: sy[$0]) }
    }

    private static func normalize01(_ v: inout [Float]) {
        var lo: Float = 0, hi: Float = 0
        vDSP_minv(v, 1, &lo, vDSP_Length(v.count))
        vDSP_maxv(v, 1, &hi, vDSP_Length(v.count))
        let range = hi - lo
        guard range > 1e-9 else { return }
        var neg = -lo, inv = 1 / range
        vDSP_vsadd(v, 1, &neg, &v, 1, vDSP_Length(v.count))
        vDSP_vsmul(v, 1, &inv, &v, 1, vDSP_Length(v.count))
    }
}
