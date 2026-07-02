import SwiftUI

/// A beat-driven equalizer for the Now Playing hero.
///
/// RoonSage can't tap the audio stream (Roon plays on the endpoint; the app is a
/// controller), so a real FFT visualizer is impossible for zone playback. Instead
/// this is driven by what the analyzer already knows about the track — its **BPM**
/// (pulse tempo), **energy/danceability** (pulse intensity) and **valence** (colour
/// warmth). It's tempo-plausible rather than sample-accurate, but it works for
/// every zone and needs no audio access at all — something a streaming client with
/// only cover art can't do.
struct BeatVisualizer: View {
    /// Beats per minute; ≤0 falls back to a gentle idle tempo.
    let bpm: Double
    /// 0…1 — taller, punchier bars when high.
    let intensity: Double
    /// 0…1 — warm (gold) when high, cool (cyan) when low.
    let warmth: Double
    let isPlaying: Bool
    let reduceMotion: Bool

    private let barCount = 40

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !isPlaying || reduceMotion)) { timeline in
            Canvas { context, size in
                render(&context, size: size, t: timeline.date.timeIntervalSinceReferenceDate)
            }
        }
        .frame(height: 40)
        .drawingGroup()
        .accessibilityHidden(true)
    }

    private func render(_ context: inout GraphicsContext, size: CGSize, t: TimeInterval) {
        let bps = max(bpm, 1) / 60          // beats per second (idle at ~1 BPS if unknown)
        let effectiveBPS = bpm > 0 ? bps : 100.0 / 60
        let energyBoost = 0.35 + 0.65 * clamp01(intensity)
        let gap: CGFloat = 3
        let barWidth = max(1, (size.width - gap * CGFloat(barCount - 1)) / CGFloat(barCount))
        let mid = size.height / 2

        for i in 0..<barCount {
            let f = Double(i) / Double(barCount - 1)     // 0…1 across the strip
            let seed = Self.hash01(i)
            let freqMul = [0.5, 1, 1, 2][i % 4]          // some bars pulse half/double tempo
            let phase = ((t * effectiveBPS * freqMul) + seed).truncatingRemainder(dividingBy: 1)
            let pulse = pow(max(0, 1 - phase), 1.6)      // sharp attack, decay each beat
            let sway = 0.5 + 0.5 * sin(t * 0.7 + f * 6.283)
            let band = (1 - f) * 0.55 + 0.45 * sway      // static-ish spectrum envelope
            var norm = 0.16 + 0.84 * ((0.45 * band + 0.55 * pulse) * energyBoost)
            norm = min(max(norm, 0.06), 1)

            let h = CGFloat(norm) * size.height
            let x = CGFloat(i) * (barWidth + gap)
            let rect = CGRect(x: x, y: mid - h / 2, width: barWidth, height: h)
            let color = barColor(height: norm)
            context.fill(Path(roundedRect: rect, cornerRadius: barWidth / 2), with: .color(color))
        }
    }

    /// Hue from valence (warm→cool); brighter/opaquer at the peaks.
    private func barColor(height: Double) -> Color {
        let hue = 0.55 - 0.44 * clamp01(warmth)          // 0.11 gold … 0.55 cyan
        return Color(hue: hue, saturation: 0.75, brightness: 0.95)
            .opacity(0.35 + 0.6 * height)
    }

    private func clamp01(_ v: Double) -> Double { min(max(v, 0), 1) }

    /// Deterministic per-bar jitter so the bars don't move in lockstep.
    static func hash01(_ i: Int) -> Double {
        var x = UInt64(i &+ 1) &* 0x9E3779B97F4A7C15
        x ^= x >> 29
        return Double(x % 1000) / 1000
    }
}
