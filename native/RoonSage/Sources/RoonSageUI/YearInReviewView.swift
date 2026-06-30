import Charts
import RoonSageCore
import SwiftUI

/// "Sonic Wrapped" — a year-in-review of the user's listening history.
/// Shows top artists, top tracks, plays-by-hour heatmap, and a shareable card.
@MainActor
public struct YearInReviewView: View {
    public init() {}
    @Environment(RoonClient.self) private var client

    @State private var stats: DatabaseManager.YearStats?
    @State private var loading = false
    @State private var selectedYear: Int = Calendar.current.component(.year, from: Date())

    private var years: [Int] {
        let current = Calendar.current.component(.year, from: Date())
        return Array((current - 4)...current).reversed()
    }

    // A year is not a quantity: interpolating the Int into a LocalizedStringKey
    // applies the locale's grouping separator ("2.026" in nl). Interpolate this
    // String instead so it stays "2026".
    private var yearText: String { String(selectedYear) }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.xl) {
                // Year picker
                HStack {
                    Label("Jaaroverzicht", systemImage: "calendar.badge.clock")
                        .font(.title2.bold())
                    Spacer()
                    Picker("Jaar", selection: $selectedYear) {
                        ForEach(years, id: \.self) { Text(verbatim: "\($0)").tag($0) }
                    }
                    .pickerStyle(.menu)
                    .tint(Color.roonGold)
                }

                if loading {
                    ProgressView().frame(maxWidth: .infinity, minHeight: 200)
                } else if let s = stats, s.totalPlays > 0 {
                    content(s)
                } else {
                    ContentUnavailableView(
                        "Geen luistergeschiedenis voor \(yearText)",
                        systemImage: "calendar.badge.exclamationmark",
                        description: Text("Importeer je Last.fm-historie in Instellingen om eerdere jaren te vullen."))
                }
            }
            .padding()
        }
        .windowWidthCapped()
        .navigationTitle("Jaaroverzicht \(yearText)")
        .toolbar {
            if stats != nil {
                ToolbarItem(placement: .primaryAction) {
                    ShareLink(item: shareText, subject: Text("Mijn \(yearText) in muziek")) {
                        Label("Deel", systemImage: "square.and.arrow.up")
                    }
                }
            }
        }
        .task(id: selectedYear) { await load() }
    }

    @ViewBuilder
    private func content(_ s: DatabaseManager.YearStats) -> some View {
        // Hero stats
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: Spacing.md) {
            statCard(value: "\(s.totalPlays)", label: "Nummers gespeeld", icon: "play.fill", color: Color.roonGold)
            statCard(value: "\(s.uniqueArtists)", label: "Artiesten", icon: "person.2.fill", color: Color.roonSuccess)
            statCard(value: "\(s.uniqueTracks)", label: "Unieke nummers", icon: "music.note", color: Color.roonInfo)
        }

        if s.longestStreak > 1 {
            Label("\(s.longestStreak) dagen op rij geluisterd", systemImage: "flame.fill")
                .font(.callout)
                .foregroundStyle(Color.roonGold)
        }

        if let first = s.firstListen {
            VStack(alignment: .leading, spacing: 4) {
                Text("Eerste nummer van \(yearText)")
                    .font(.caption).foregroundStyle(.secondary)
                Text(first.title).font(.callout.bold()).lineLimit(1)
                if let a = first.artist { Text(a).font(.caption).foregroundStyle(.secondary) }
            }
            .padding(Spacing.md)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.background.secondary, in: RoundedRectangle(cornerRadius: Radius.md))
        }

        // Top artists
        if !s.topArtists.isEmpty {
            sectionHeader("Top Artiesten", icon: "person.fill")
            let maxArtistCount = s.topArtists.first?.count ?? 1
            VStack(spacing: Spacing.sm) {
                ForEach(Array(s.topArtists.enumerated()), id: \.offset) { idx, a in
                    HStack(spacing: Spacing.md) {
                        Text("\(idx + 1)")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .frame(width: 20, alignment: .trailing)
                        Text(a.artist).font(.callout).lineLimit(1)
                        Spacer()
                        GeometryReader { geo in
                            RoundedRectangle(cornerRadius: 3)
                                .fill(Color.roonGold.opacity(0.7))
                                .frame(width: geo.size.width * CGFloat(a.count) / CGFloat(maxArtistCount))
                        }
                        .frame(width: 80, height: 8)
                        Text("\(a.count)")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }

        // Top tracks
        if !s.topTracks.isEmpty {
            sectionHeader("Top Nummers", icon: "music.note")
            VStack(spacing: Spacing.sm) {
                ForEach(Array(s.topTracks.enumerated()), id: \.offset) { idx, t in
                    HStack(spacing: Spacing.md) {
                        Text("\(idx + 1)")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .frame(width: 20, alignment: .trailing)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(t.title).font(.callout).lineLimit(1)
                            if let a = t.artist { Text(a).font(.caption).foregroundStyle(.secondary) }
                        }
                        Spacer()
                        Badge("\(t.count)×")
                    }
                }
            }
        }

        // Plays by hour
        if s.playsByHour.contains(where: { $0 > 0 }) {
            sectionHeader("Speelpatroon per uur", icon: "clock")
            Chart {
                ForEach(0..<24, id: \.self) { hour in
                    BarMark(
                        x: .value("Uur", hour),
                        y: .value("Nummers", s.playsByHour[hour])
                    )
                    .foregroundStyle(
                        LinearGradient(
                            colors: [Color.roonGold, Color.roonGold.opacity(0.4)],
                            startPoint: .top, endPoint: .bottom)
                    )
                    .cornerRadius(3)
                }
            }
            .chartXAxis {
                AxisMarks(values: [0, 6, 12, 18, 23]) { val in
                    AxisGridLine()
                    AxisValueLabel {
                        if let h = val.as(Int.self) {
                            Text("\(h)u").font(.caption)
                        }
                    }
                }
            }
            .frame(height: 140)
        }
    }

    private func statCard(value: String, label: String, icon: String, color: Color) -> some View {
        VStack(spacing: 6) {
            Image(systemName: icon).foregroundStyle(color).font(.title3)
            Text(value).font(.title2.bold().monospacedDigit())
            Text(label).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(Spacing.md)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: Radius.md))
    }

    private func sectionHeader(_ title: String, icon: String) -> some View {
        Label(title, systemImage: icon)
            .font(.headline)
            .padding(.top, 4)
    }

    private var shareText: String {
        guard let s = stats else { return "" }
        var lines = ["Mijn \(s.year) in muziek"]
        lines.append("\(s.totalPlays) nummers gespeeld")
        lines.append("\(s.uniqueArtists) artiesten ontdekt")
        if let top = s.topArtists.first { lines.append("Meest gespeeld: \(top.artist) (\(top.count)x)") }
        if s.longestStreak > 1 { lines.append("Langste streak: \(s.longestStreak) dagen") }
        return lines.joined(separator: "\n")
    }

    private func load() async {
        loading = true
        defer { loading = false }
        // Thin clients have no local listening_history; the client routes this to
        // the server. Keep last-known stats on a transient nil so we don't flash
        // the empty state.
        if let s = await client.yearInReview(year: selectedYear) {
            stats = s
        }
    }
}
