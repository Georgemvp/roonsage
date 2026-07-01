import SwiftUI
import RoonSageCore

// MARK: - Ontdek-inzichten (discovery analytics dashboard)
//
// Presented as a sheet from the Ontdekkingen toolbar. Shows how the engine is
// doing: your approval rate, how many you've saved vs. skipped, which producers
// earn their keep (accept-rate), and the genres you save most. All data comes
// from GET /discovery/stats (server-of-record); this view only renders it.
// Built on List + .plainCardRow() — the iOS-26-safe pattern.

@MainActor
public struct DiscoverInsightsView: View {
    @Environment(RoonClient.self) private var client

    @State private var stats: DiscoveryStatsDTO?
    @State private var loading = true

    public init() {}

    public var body: some View {
        Group {
            if loading {
                ProgressView("Inzichten laden…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let s = stats, s.accepted + s.rejected + s.pending > 0 {
                content(s)
            } else {
                emptyState
            }
        }
        .navigationTitle("Ontdek-inzichten")
        .task { await load() }
    }

    private func load() async {
        loading = true
        stats = await client.discoveryStats()
        loading = false
    }

    private func content(_ s: DiscoveryStatsDTO) -> some View {
        List {
            metrics(s).plainCardRow()

            if !s.producers.isEmpty {
                Section("Bron-effectiviteit") {
                    ForEach(s.producers) { ProducerRow(stat: $0).plainCardRow() }
                }
                .headerProminence(.increased)
            }

            if !s.topGenres.isEmpty {
                Section("Meest bewaarde genres") {
                    let maxCount = s.topGenres.map(\.count).max() ?? 1
                    ForEach(s.topGenres) { g in
                        GenreRow(genre: g, fraction: Double(g.count) / Double(maxCount)).plainCardRow()
                    }
                }
                .headerProminence(.increased)
            }
        }
        .listStyle(.plain)
    }

    private func metrics(_ s: DiscoveryStatsDTO) -> some View {
        HStack(spacing: Spacing.md) {
            MetricTile(label: "Goedgekeurd", value: "\(Int((s.approvalRate * 100).rounded()))%",
                       tint: s.accepted + s.rejected > 0 ? .roonGold : .secondary)
            MetricTile(label: "Bewaard", value: "\(s.accepted)", tint: .roonSuccess)
            MetricTile(label: "Overgeslagen", value: "\(s.rejected)", tint: .secondary)
        }
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("Nog geen inzichten", systemImage: "chart.bar")
        } description: {
            Text("Zodra je aanbevelingen bewaart of overslaat, verschijnen hier je goedkeur-ratio en welke bronnen het beste bij je smaak passen.")
        }
    }
}

// MARK: - Rows

private struct MetricTile: View {
    let label: String
    let value: String
    var tint: Color = .roonGold

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Text(value)
                .font(.title2.weight(.semibold))
                .foregroundStyle(tint)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Spacing.md)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: Radius.lg))
    }
}

private struct ProducerRow: View {
    let stat: DiscoveryStatsDTO.ProducerStat

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            HStack {
                Text(DiscoveryProducerLabel.nl(stat.producer))
                    .font(.subheadline)
                Spacer()
                if let rate = stat.acceptRate {
                    Text("\(Int((rate * 100).rounded()))%")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Color.roonGold)
                } else {
                    Text("nog geen beslissingen")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            if let rate = stat.acceptRate {
                InsightBar(fraction: rate)
            }
            Text("\(stat.contributions) aanbevelingen · \(stat.accepted) bewaard · \(stat.rejected) overgeslagen")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }
}

private struct GenreRow: View {
    let genre: DiscoveryStatsDTO.GenreStat
    let fraction: Double

    var body: some View {
        HStack(spacing: Spacing.md) {
            Text(genre.genre.capitalized)
                .font(.subheadline)
                .frame(width: 120, alignment: .leading)
                .lineLimit(1)
            InsightBar(fraction: fraction, tint: .roonInfo)
            Text("\(genre.count)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 28, alignment: .trailing)
        }
        .padding(.vertical, 2)
    }
}

/// A 0…1 proportional bar. GeometryReader constrained to 6 pt tall — safe inside
/// the width-clamped List row (same idiom as the feed's ScoreBar).
private struct InsightBar: View {
    let fraction: Double
    var tint: Color = .roonGold

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule().fill(tint)
                    .frame(width: max(0, min(1, fraction)) * geo.size.width)
            }
        }
        .frame(height: 6)
    }
}

// MARK: - Shared producer labels

/// Short Dutch labels for the discovery producers — shared by the feed's source
/// badges, the insights dashboard, and the analyzer's tuning settings so none
/// of the three drift apart.
public enum DiscoveryProducerLabel {
    public static func nl(_ id: String) -> String {
        switch id {
        case "similar-artist-web":   "Vergelijkbaar"
        case "charts":               "Charts"
        case "release-radar":        "Nieuw"
        case "gap-fill":             "Aanvulling"
        case "artist-relationships": "Samenwerking"
        case "listenbrainz-radio":   "ListenBrainz"
        case "ai-picks":             "AI"
        case "discogs-labels":       "Discogs"
        case "qobuz-catalog":        "Qobuz"
        default:                     id
        }
    }
}
