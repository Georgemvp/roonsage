import RoonSageCore
import SwiftUI

/// Build a beatmatched, harmonically-mixed DJ set from analyzed audio features.
@MainActor
public struct DJSetView: View {
    public init() {}
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
    @State private var showRebuildConfirm = false

    public var body: some View {
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
                        Button {
                            if set.isEmpty { build() } else { showRebuildConfirm = true }
                        } label: {
                            Label("Build DJ Set", systemImage: "slider.horizontal.3")
                        }
                        .buttonStyle(.borderedProminent)
                        .confirmationDialog(
                            "Rebuild the set? The current set will be replaced.",
                            isPresented: $showRebuildConfirm, titleVisibility: .visible
                        ) {
                            Button("Rebuild", role: .destructive) { build() }
                            Button("Cancel", role: .cancel) {}
                        }
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

    private var setlistText: String {
        SetlistExport.text(
            name: saveName.trimmingCharacters(in: .whitespaces).isEmpty ? "DJ Set" : saveName,
            tracks: set.enumerated().map { i, c in
                .init(n: i + 1, title: c.title, artist: c.artist, bpm: c.bpm, camelot: c.camelot)
            })
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
            ShareLink(item: setlistText) {
                Label("Exporteer", systemImage: "square.and.arrow.up")
            }
            .help("Deel de setlist (met BPM en toonsoort)")
            Button {
                guard let z = selectedZoneID else { return }
                Task { await client.playDJSet(set, zoneID: z) }
            } label: { Label("Play", systemImage: "play.fill") }
            .buttonStyle(.borderedProminent).disabled(selectedZoneID == nil)
        }

        // Set analysis: BPM flow, energy arc, harmonic transitions
        VStack(alignment: .leading, spacing: 6) {
            Label("Tempo", systemImage: "metronome").font(.caption).foregroundStyle(.secondary)
            BPMCurvePreview(bpms: set.map { $0.bpm })
                .frame(height: 50)
            Label("Energie", systemImage: "bolt.fill").font(.caption).foregroundStyle(.secondary)
            EnergyCurvePreview(energies: set.map { $0.energy })
                .frame(height: 34)
            HarmonicTransitionStrip(camelots: set.map { $0.camelot })
        }
        .padding(.vertical, 4)

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
                HStack(spacing: 0) {
                    Button { move(i, by: -1) } label: { Image(systemName: "chevron.up") }
                        .disabled(i == 0).help("Move up")
                    Button { move(i, by: 1) } label: { Image(systemName: "chevron.down") }
                        .disabled(i == set.count - 1).help("Move down")
                    Button(role: .destructive) {
                        set.remove(at: i)
                    } label: { Image(systemName: "trash") }.help("Remove from set")
                }
                .buttonStyle(.borderless).controlSize(.small).foregroundStyle(.secondary)
            }
            .padding(.vertical, 2)
        }
    }

    private func move(_ index: Int, by offset: Int) {
        let target = index + offset
        guard set.indices.contains(index), set.indices.contains(target) else { return }
        set.swapAt(index, target)
    }

    private func build() {
        let tags = tagsText.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        set = client.buildDJSet(count: count, startBPM: startBPM, endBPM: endBPM, curve: curve, tags: tags)
        status = set.isEmpty ? "No tracks matched — widen the BPM range or drop the tags." : nil
        if saveName.isEmpty { saveName = "DJ set \(Int(startBPM))–\(Int(endBPM)) BPM" }
    }
}

// MARK: - BPM flow preview

/// Sparkline of the set's tempo progression so the curve is visible at a glance.
private struct BPMCurvePreview: View {
    let bpms: [Double]

    public var body: some View {
        Canvas { ctx, size in
            guard bpms.count > 1 else { return }
            let lo = (bpms.min() ?? 0) - 2
            let hi = (bpms.max() ?? 1) + 2
            let span = max(1, hi - lo)
            let stepX = size.width / CGFloat(bpms.count - 1)
            func pt(_ i: Int) -> CGPoint {
                let y = size.height - CGFloat((bpms[i] - lo) / span) * size.height
                return CGPoint(x: CGFloat(i) * stepX, y: y)
            }
            // Filled area under the line.
            var area = Path()
            area.move(to: CGPoint(x: 0, y: size.height))
            for i in 0..<bpms.count { area.addLine(to: pt(i)) }
            area.addLine(to: CGPoint(x: size.width, y: size.height))
            area.closeSubpath()
            ctx.fill(area, with: .color(Color.roonGold.opacity(0.15)))

            var line = Path()
            line.move(to: pt(0))
            for i in 1..<bpms.count { line.addLine(to: pt(i)) }
            ctx.stroke(line, with: .color(Color.roonGold), lineWidth: 2)

            for i in 0..<bpms.count {
                let p = pt(i)
                ctx.fill(Path(ellipseIn: CGRect(x: p.x - 2, y: p.y - 2, width: 4, height: 4)),
                         with: .color(Color.roonGold))
            }
            ctx.draw(Text("\(Int(hi)) BPM").font(.caption2).foregroundColor(.secondary),
                     at: CGPoint(x: 28, y: 8))
            ctx.draw(Text("\(Int(lo)) BPM").font(.caption2).foregroundColor(.secondary),
                     at: CGPoint(x: 28, y: size.height - 8))
        }
    }
}

// MARK: - Energy arc

/// Energy progression of the set on a fixed 0–1 scale (so the build-up/wind-down
/// shape is honest, not auto-stretched).
private struct EnergyCurvePreview: View {
    let energies: [Double]

    var body: some View {
        Canvas { ctx, size in
            guard energies.count > 1 else { return }
            let stepX = size.width / CGFloat(energies.count - 1)
            func pt(_ i: Int) -> CGPoint {
                let e = min(1, max(0, energies[i]))
                return CGPoint(x: CGFloat(i) * stepX, y: size.height - CGFloat(e) * size.height)
            }
            var area = Path()
            area.move(to: CGPoint(x: 0, y: size.height))
            for i in 0..<energies.count { area.addLine(to: pt(i)) }
            area.addLine(to: CGPoint(x: size.width, y: size.height))
            area.closeSubpath()
            ctx.fill(area, with: .linearGradient(
                Gradient(colors: [.orange.opacity(0.30), .orange.opacity(0.05)]),
                startPoint: CGPoint(x: 0, y: 0), endPoint: CGPoint(x: 0, y: size.height)))

            var line = Path()
            line.move(to: pt(0))
            for i in 1..<energies.count { line.addLine(to: pt(i)) }
            ctx.stroke(line, with: .color(.orange), lineWidth: 2)
        }
    }
}

// MARK: - Harmonic transitions

/// One pill per transition between consecutive tracks, coloured by how cleanly
/// the keys mix (gold = harmonic, green = same key, grey = tempo-only), with a
/// summary so key clashes are obvious before you play the set.
private struct HarmonicTransitionStrip: View {
    let camelots: [String]

    private var relations: [RoonClient.HarmonicRelation] {
        guard camelots.count > 1 else { return [] }
        return (0..<camelots.count - 1).map {
            RoonClient.harmonicRelation(current: camelots[$0], candidate: camelots[$0 + 1])
        }
    }

    private func color(_ r: RoonClient.HarmonicRelation) -> Color {
        switch r {
        case .harmonic: .roonGold
        case .sameKey:  .green
        case .tempo:    .gray.opacity(0.4)
        }
    }

    var body: some View {
        let rels = relations
        let smooth = rels.filter { $0 != .tempo }.count
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 2) {
                ForEach(Array(rels.enumerated()), id: \.offset) { _, r in
                    RoundedRectangle(cornerRadius: 2)
                        .fill(color(r))
                        .frame(height: 6)
                }
            }
            if !rels.isEmpty {
                Text("\(smooth)/\(rels.count) harmonische overgangen")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
    }
}
