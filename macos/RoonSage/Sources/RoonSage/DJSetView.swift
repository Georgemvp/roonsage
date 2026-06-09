import RoonSageCore
import SwiftUI

/// Build a beatmatched, harmonically-mixed DJ set from analyzed audio features.
@MainActor
struct DJSetView: View {
    @Environment(RoonClient.self) private var client

    @State private var count = 20
    @State private var startBPM = 120.0
    @State private var endBPM = 128.0
    @State private var curve: DJSetBuilder.Curve = .rampUp
    @State private var tagsText = ""
    @State private var selectedZoneID: String?
    @State private var set: [DatabaseManager.DJCandidate] = []
    @State private var saveName = ""
    @State private var status: String?

    var body: some View {
        let stats = client.audioFeaturesStats()
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if stats.matched == 0 {
                    ContentUnavailableView(
                        "No analyzed tracks yet",
                        systemImage: "waveform.path.ecg",
                        description: Text("Run roonsage-analyzer on your music host, then sync in Settings → Audio Analyzer.")
                    )
                } else {
                    Text("\(stats.matched) tracks with BPM/key available").font(.caption).foregroundStyle(.secondary)

                    HStack(spacing: 20) {
                        Stepper("Tracks: \(count)", value: $count, in: 5...60, step: 5)
                        Picker("Curve", selection: $curve) {
                            ForEach(DJSetBuilder.Curve.allCases, id: \.self) { Text($0.label).tag($0) }
                        }.frame(maxWidth: 160)
                    }

                    HStack(spacing: 20) {
                        Stepper("Start: \(Int(startBPM)) BPM", value: $startBPM, in: 60...200, step: 1)
                        Stepper("End: \(Int(endBPM)) BPM", value: $endBPM, in: 60...200, step: 1)
                    }

                    HStack {
                        Text("Tags").foregroundStyle(.secondary)
                        TextField("optional, comma-separated (e.g. driving, deep house)", text: $tagsText)
                            .textFieldStyle(.roundedBorder)
                    }

                    HStack {
                        if !client.zones.isEmpty {
                            Picker("Zone", selection: $selectedZoneID) {
                                Text("Select zone…").tag(Optional<String>.none)
                                ForEach(client.zones) { z in
                                    Label(z.displayName, systemImage: z.state.icon).tag(Optional(z.id))
                                }
                            }.frame(maxWidth: 220)
                        }
                        Spacer()
                        Button { build() } label: {
                            Label("Build DJ Set", systemImage: "slider.horizontal.3")
                        }
                        .buttonStyle(.borderedProminent)
                    }

                    if let status { Text(status).font(.callout).foregroundStyle(.secondary) }

                    if !set.isEmpty { resultView }
                }
            }
            .padding(24)
        }
        .navigationTitle("DJ Set")
        .onAppear { if selectedZoneID == nil { selectedZoneID = client.selectedZone?.id } }
    }

    @ViewBuilder
    private var resultView: some View {
        Divider()
        HStack {
            Text("\(set.count)-track set").font(.headline)
            Spacer()
            TextField("Playlist name", text: $saveName).textFieldStyle(.roundedBorder).frame(width: 160)
            Button("Save") {
                let n = saveName.trimmingCharacters(in: .whitespaces)
                guard !n.isEmpty else { return }
                client.saveDJSet(name: n, set: set); status = "Saved playlist “\(n)”."
            }.disabled(saveName.trimmingCharacters(in: .whitespaces).isEmpty)
            Button {
                guard let z = selectedZoneID else { return }
                Task { await client.playDJSet(set, zoneID: z) }
            } label: { Label("Play", systemImage: "play.fill") }
            .buttonStyle(.borderedProminent).disabled(selectedZoneID == nil)
        }

        ForEach(Array(set.enumerated()), id: \.offset) { i, t in
            HStack(spacing: 10) {
                Text("\(i + 1)").font(.caption.monospacedDigit()).foregroundStyle(.tertiary).frame(width: 24, alignment: .trailing)
                AlbumArtView(imageKey: t.imageKey, size: 40)
                VStack(alignment: .leading, spacing: 2) {
                    Text(t.title).lineLimit(1)
                    if let a = t.artist { Text(a).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                }
                Spacer()
                Text("\(Int(t.bpm)) BPM").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                Text(t.camelot).font(.caption.monospacedDigit().bold())
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background(.quaternary, in: Capsule())
            }
            .padding(.vertical, 2)
        }
    }

    private func build() {
        let tags = tagsText.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        set = client.buildDJSet(count: count, startBPM: startBPM, endBPM: endBPM, curve: curve, tags: tags)
        status = set.isEmpty ? "No tracks matched — widen the BPM range or drop the tags." : nil
        if saveName.isEmpty { saveName = "DJ set \(Int(startBPM))–\(Int(endBPM)) BPM" }
    }
}
