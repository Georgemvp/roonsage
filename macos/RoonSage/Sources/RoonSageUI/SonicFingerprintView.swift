import SwiftUI
import RoonSageCore

@MainActor
public struct SonicFingerprintView: View {
    public init() {}
    @Environment(RoonClient.self) private var client
    @State private var fingerprint: RoonClient.Fingerprint?
    @State private var isLoading = false
    @State private var loaded = false

    public var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: Spacing.xl) {
                if let fp = fingerprint {
                    profileCard(fp)
                    if !fp.recommendations.isEmpty { recommendationsCard(fp) }
                } else if isLoading {
                    ContentUnavailableView("Computing your sonic DNA…", systemImage: "waveform.path.ecg")
                        .frame(maxWidth: .infinity, minHeight: 300)
                } else if loaded {
                    ContentUnavailableView(
                        "No analyzed tracks yet",
                        systemImage: "waveform.path.ecg",
                        description: Text("Run the audio analyzer (Library tab) so your musical DNA can be computed.")
                    )
                    .frame(maxWidth: .infinity, minHeight: 300)
                }
            }
            .padding(Spacing.xl)
        }
        .navigationTitle("Sonic DNA")
        .toolbar {
            Button { Task { await load(force: true) } } label: {
                Image(systemName: "arrow.clockwise")
            }
            .help("Recompute")
            .disabled(isLoading)
        }
        .task { await load(force: false) }
    }

    // MARK: - Profile card (radar + stats)

    @ViewBuilder
    private func profileCard(_ fp: RoonClient.Fingerprint) -> some View {
        let p = fp.profile
        VStack(alignment: .leading, spacing: Spacing.md) {
            Text("Your Musical DNA").font(.headline)
            Text("Averaged from your \(fp.seedCount) most-played analyzed tracks.")
                .font(.caption).foregroundStyle(.secondary)

            HStack(alignment: .center, spacing: Spacing.xl) {
                RadarChart(axes: [
                    ("Energy", p.energy),
                    ("Tempo", p.tempo),
                    ("Major", p.majorAffinity),
                    ("Variety", p.tempoVariety),
                    ("Tags", p.tagRichness),
                ])
                .frame(width: 220, height: 220)

                VStack(alignment: .leading, spacing: Spacing.sm) {
                    statRow("Avg tempo", "\(Int(p.avgBPM)) BPM")
                    statRow("Energy", percent(p.energy))
                    statRow("Major key affinity", percent(p.majorAffinity))
                    statRow("Tempo variety", percent(p.tempoVariety))
                    if !p.topTags.isEmpty {
                        Text("Signature tags").font(.caption).foregroundStyle(.secondary).padding(.top, 4)
                        FlowTags(tags: p.topTags.map { $0.tag })
                    }
                }
                Spacer()
            }
        }
        .padding(Spacing.lg)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: Radius.lg))
    }

    private func statRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).font(.callout).foregroundStyle(.secondary)
            Spacer()
            Text(value).font(.callout.monospacedDigit().weight(.medium))
        }
        .frame(width: 220)
    }

    // MARK: - Recommendations

    @ViewBuilder
    private func recommendationsCard(_ fp: RoonClient.Fingerprint) -> some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            HStack {
                Text("Recommended for You").font(.headline)
                Spacer()
                Button {
                    play { await client.curateTracks(asTracks(fp.recommendations), zoneID: $0) }
                } label: {
                    Label("Play all", systemImage: "play.fill")
                }
                .buttonStyle(.bordered).controlSize(.small)
                .disabled(client.selectedZone == nil)
            }
            Text("Closest to your taste, discovery-friendly.")
                .font(.caption).foregroundStyle(.secondary)

            ForEach(fp.recommendations) { scored in
                HStack(spacing: Spacing.md) {
                    AlbumArtView(imageKey: scored.track.imageKey, size: 40)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(scored.track.title).font(.callout).lineLimit(1)
                        Text(scored.track.artist ?? "Unknown")
                            .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer()
                    Text(percent(scored.similarity))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.tertiary)
                    Button {
                        let t = scored.track
                        play { await client.playTrack(id: t.id, title: t.title, artist: t.artist, zoneID: $0) }
                    } label: {
                        Image(systemName: "play.fill")
                    }
                    .buttonStyle(.borderless)
                    .disabled(client.selectedZone == nil)
                    .help("Play now")
                }
            }
        }
        .padding(Spacing.lg)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: Radius.lg))
    }

    // MARK: - Helpers

    private func asTracks(_ scored: [SonicEngine.Scored]) -> [TrackRecord] {
        scored.map { TrackRecord(id: $0.track.id, title: $0.track.title, artist: $0.track.artist, album: $0.track.album) }
    }

    private func percent(_ v: Double) -> String { "\(Int((v * 100).rounded()))%" }

    private func play(_ action: @escaping (String) async -> Void) {
        guard let zone = client.selectedZone else { return }
        Task { await action(zone.id) }
    }

    private func load(force: Bool) async {
        if fingerprint != nil && !force { return }
        isLoading = true
        if force { await client.invalidateSonicCache() }
        fingerprint = await client.sonicFingerprint()
        isLoading = false
        loaded = true
    }
}

// MARK: - Radar chart

private struct RadarChart: View {
    /// (label, value 0…1)
    let axes: [(String, Double)]

    public var body: some View {
        Canvas { ctx, size in
            let center = CGPoint(x: size.width / 2, y: size.height / 2)
            let radius = min(size.width, size.height) / 2 - 26
            let n = axes.count
            guard n >= 3 else { return }

            // Concentric grid rings.
            for ring in 1...4 {
                let r = radius * CGFloat(ring) / 4
                var path = Path()
                for i in 0..<n {
                    let pt = point(center: center, radius: r, index: i, count: n)
                    if i == 0 { path.move(to: pt) } else { path.addLine(to: pt) }
                }
                path.closeSubpath()
                ctx.stroke(path, with: .color(.gray.opacity(0.18)), lineWidth: 1)
            }

            // Spokes.
            for i in 0..<n {
                var spoke = Path()
                spoke.move(to: center)
                spoke.addLine(to: point(center: center, radius: radius, index: i, count: n))
                ctx.stroke(spoke, with: .color(.gray.opacity(0.18)), lineWidth: 1)
            }

            // Data polygon.
            var shape = Path()
            for i in 0..<n {
                let v = max(0, min(1, axes[i].1))
                let pt = point(center: center, radius: radius * CGFloat(v), index: i, count: n)
                if i == 0 { shape.move(to: pt) } else { shape.addLine(to: pt) }
            }
            shape.closeSubpath()
            ctx.fill(shape, with: .color(Color.roonGold.opacity(0.25)))
            ctx.stroke(shape, with: .color(Color.roonGold), lineWidth: 2)

            // Axis labels.
            for i in 0..<n {
                let pt = point(center: center, radius: radius + 14, index: i, count: n)
                let text = Text(axes[i].0).font(.caption2).foregroundColor(.secondary)
                ctx.draw(text, at: pt, anchor: .center)
            }
        }
    }

    private func point(center: CGPoint, radius: CGFloat, index: Int, count: Int) -> CGPoint {
        let angle = -CGFloat.pi / 2 + 2 * .pi * CGFloat(index) / CGFloat(count)
        return CGPoint(x: center.x + radius * cos(angle), y: center.y + radius * sin(angle))
    }
}

// MARK: - Simple wrapping tag row

private struct FlowTags: View {
    let tags: [String]
    public var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 60), spacing: 6, alignment: .leading)],
                  alignment: .leading, spacing: 6) {
            ForEach(tags, id: \.self) { Badge($0, tint: .roonGold) }
        }
        .frame(width: 220, alignment: .leading)
    }
}
