import AudioAnalysis
import RoonSageCore
import SwiftUI

/// LMS-style "Info" modal: everything the pipeline knows about one track —
/// analysis (BPM, toonsoort, energie, LUFS), enrichment (populariteit, tags,
/// moods) and luistergedrag (playcount, laatst gespeeld). Rows appear only
/// when their value exists; an unanalyzed track shows a short explanation.
@MainActor
struct TrackInfoSheet: View {
    @Environment(RoonClient.self) private var client
    @Environment(\.dismiss) private var dismiss
    let track: DatabaseManager.LibraryTrackRow

    @State private var features: DatabaseManager.AudioFeatureRow?
    @State private var playCount: Int = 0
    @State private var lastPlayed: String?
    @State private var loaded = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack(spacing: Spacing.lg) {
                        AlbumArtView(imageKey: track.imageKey, size: 64, cornerRadius: Radius.md)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(track.title).font(.headline).lineLimit(2)
                            if let a = track.artist { Text(a).font(.subheadline).foregroundStyle(.secondary) }
                            if let al = track.album { Text(al).font(.caption).foregroundStyle(.tertiary) }
                        }
                    }
                }

                Section {
                    NavigationLink {
                        SimilarTracksView(seed: SonicSeed(title: track.title, artist: track.artist,
                                                          album: track.album, imageKey: track.imageKey))
                            .navigationDestination(for: SonicSeed.self) { SimilarTracksView(seed: $0) }
                    } label: {
                        Label("Sonisch vergelijkbaar", systemImage: "waveform.path.ecg")
                    }
                }

                if let f = features {
                    Section("Analyse") {
                        if let bpm = f.bpm, bpm > 0 {
                            LabeledContent("Tempo") {
                                Text("\(Int(bpm.rounded())) BPM\(confidenceSuffix(f.bpmConfidence))")
                            }
                        }
                        if let cam = f.camelot, !cam.isEmpty {
                            LabeledContent("Toonsoort", value: keyLabel(f))
                        }
                        if let e = f.energy {
                            LabeledContent("Energie", value: String(format: "%.0f%%", e * 100))
                        }
                        if let d = f.duration, d > 0 {
                            LabeledContent("Duur", value: formatDuration(d))
                        }
                        if let l = f.loudness {
                            LabeledContent("Loudness", value: String(format: "%.1f LUFS", l))
                        }
                    }
                    let tags = jsonStrings(f.tags)
                    if !tags.isEmpty || f.popularity != nil {
                        Section("Verrijking") {
                            if let p = f.popularity, p > 0 {
                                LabeledContent("Populariteit (Deezer)", value: "\(p)")
                            }
                            if !tags.isEmpty {
                                LabeledContent("Tags", value: tags.prefix(6).joined(separator: ", "))
                            }
                            let moods = topMoods(f.moods)
                            if !moods.isEmpty {
                                LabeledContent("Stemming", value: moods)
                            }
                        }
                    }
                } else if loaded {
                    Section {
                        Text("Nog niet geanalyseerd — dit nummer heeft (nog) geen lokaal bestand of wacht op de analyzer.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }

                if playCount > 0 {
                    Section("Luistergedrag") {
                        LabeledContent("Keer gespeeld", value: "\(playCount)")
                        if let lastPlayed { LabeledContent("Laatst gespeeld", value: lastPlayed) }
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Info")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    BookmarkButton(isOn: client.isBookmarkedTrack(title: track.title, artist: track.artist)) {
                        Task { await client.toggleBookmarkTrack(title: track.title, artist: track.artist, album: track.album) }
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Gereed") { dismiss() }
                }
            }
        }
        .task {
            await client.ensureBookmarksLoaded()
            let mk = track.matchKey
                ?? TrackIdentity.matchKey(artist: track.artist, album: track.album, title: track.title)
            features = await client.database?.audioFeatureRow(matchKey: mk)
            let stats = await client.playStats()
            if let stat = stats.first(where: { $0.matchKey == mk }) {
                playCount = stat.count
                lastPlayed = String(stat.lastPlayed.prefix(10))   // ISO date part
            }
            loaded = true
        }
    }

    private func confidenceSuffix(_ c: Double?) -> String {
        guard let c, c > 0 else { return "" }
        return String(format: " (%.0f%% zeker)", c * 100)
    }

    private func keyLabel(_ f: DatabaseManager.AudioFeatureRow) -> String {
        var parts: [String] = []
        if let root = f.keyRoot, !root.isEmpty {
            let mode = (f.keyMode == "minor") ? "mineur" : "majeur"
            parts.append("\(root) \(mode)")
        }
        if let cam = f.camelot, !cam.isEmpty { parts.append("Camelot \(cam)") }
        return parts.joined(separator: " · ")
    }

    private func formatDuration(_ seconds: Double) -> String {
        let s = Int(seconds.rounded())
        return String(format: "%d:%02d", s / 60, s % 60)
    }

    private func jsonStrings(_ json: String?) -> [String] {
        guard let json, let data = json.data(using: .utf8),
              let arr = try? JSONSerialization.jsonObject(with: data) as? [Any] else { return [] }
        return arr.compactMap { $0 as? String }
    }

    private func topMoods(_ json: String?) -> String {
        guard let json, let data = json.data(using: .utf8),
              let map = try? JSONDecoder().decode([String: Float].self, from: data) else { return "" }
        return map.sorted { $0.value > $1.value }.prefix(3)
            .map { RoonClient.moodLabel($0.key) }.joined(separator: ", ")
    }
}
