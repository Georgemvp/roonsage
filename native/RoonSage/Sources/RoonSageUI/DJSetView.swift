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
    // Loaded in .task — a DB read in `body` blocked main on every render.
    @State private var stats: (total: Int, matched: Int) = (0, 0)

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if stats.matched == 0 {
                    ContentUnavailableView(
                        "Nog geen geanalyseerde tracks",
                        systemImage: "waveform.path.ecg",
                        description: Text("Draai roonsage-analyzer op je muziek-host en synchroniseer daarna in Instellingen → Audio Analyzer.")
                    )
                } else {
                    Text("\(stats.matched) tracks met BPM/toonsoort beschikbaar").font(.caption).foregroundStyle(.secondary)

                    HStack(spacing: 20) {
                        Stepper("Tracks: \(count)", value: $count, in: 5...60, step: 5)
                        Picker("Curve", selection: $curve) {
                            ForEach(DJSetBuilder.Curve.allCases, id: \.self) { Text($0.label).tag($0) }
                        }.frame(maxWidth: 160)
                    }

                    HStack(spacing: 20) {
                        Stepper("Start: \(Int(startBPM)) BPM", value: $startBPM, in: 60...200, step: 1)
                        Stepper("Eind: \(Int(endBPM)) BPM", value: $endBPM, in: 60...200, step: 1)
                    }

                    HStack {
                        Text("Tags").foregroundStyle(.secondary)
                        TextField("optioneel, kommagescheiden (bijv. driving, deep house)", text: $tagsText)
                            .textFieldStyle(.roundedBorder)
                    }

                    HStack {
                        if !client.zones.isEmpty {
                            Picker("Zone", selection: $selectedZoneID) {
                                Text("Kies zone…").tag(Optional<String>.none)
                                ForEach(client.zones) { z in
                                    Label(z.displayName, systemImage: z.state.icon).tag(Optional(z.id))
                                }
                            }.frame(maxWidth: 220)
                        }
                        Spacer()
                        Button {
                            if set.isEmpty { build() } else { showRebuildConfirm = true }
                        } label: {
                            Label("Bouw DJ-set", systemImage: "slider.horizontal.3")
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(Color.roonGold)
                        .confirmationDialog(
                            "Set opnieuw bouwen? De huidige set wordt vervangen.",
                            isPresented: $showRebuildConfirm, titleVisibility: .visible
                        ) {
                            Button("Opnieuw bouwen", role: .destructive) { build() }
                            Button("Annuleer", role: .cancel) {}
                        }
                    }

                    if let status { Text(status).font(.callout).foregroundStyle(.secondary) }

                    if !set.isEmpty { resultView }
                }
            }
            .padding(24)
        }
        .windowWidthCapped()
        .navigationTitle("DJ Set")
        .onAppear { if selectedZoneID == nil { selectedZoneID = client.selectedZone?.id } }
        .task { stats = await client.audioFeaturesStats() }
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
            Text("Set van \(set.count) tracks").font(.headline)
            Spacer()
            TextField("Naam playlist", text: $saveName).textFieldStyle(.roundedBorder).frame(width: 160)
            Button("Bewaar") {
                let n = saveName.trimmingCharacters(in: .whitespaces)
                guard !n.isEmpty else { return }
                client.saveDJSet(name: n, set: set); status = "Playlist “\(n)” bewaard."
            }.disabled(saveName.trimmingCharacters(in: .whitespaces).isEmpty)
            ShareLink(item: setlistText) {
                Label("Exporteer", systemImage: "square.and.arrow.up")
            }
            .help("Deel de setlist (met BPM en toonsoort)")
            Button {
                guard let z = selectedZoneID else { return }
                Task { await client.playDJSet(set, zoneID: z) }
            } label: { Label("Speel", systemImage: "play.fill") }
            .buttonStyle(.borderedProminent).tint(Color.roonGold).disabled(selectedZoneID == nil)
            .help(selectedZoneID == nil ? "Kies eerst een zone" : "Speel de set af")
        }

        // Set analysis: BPM flow, energy arc, harmonic transitions
        VStack(alignment: .leading, spacing: 6) {
            Label("Tempo", systemImage: "metronome").font(.caption).foregroundStyle(.secondary)
            BPMCurvePreview(bpms: set.map { $0.bpm })
                .frame(height: 50)
                .accessibilityElement()
                .accessibilityLabel("Tempoverloop: \(Int(set.first?.bpm ?? 0)) tot \(Int(set.last?.bpm ?? 0)) BPM over \(set.count) tracks")
            Label("Energie", systemImage: "bolt.fill").font(.caption).foregroundStyle(.secondary)
            EnergyCurvePreview(energies: set.map { $0.energy })
                .frame(height: 34)
                .accessibilityElement()
                .accessibilityLabel("Energieboog over \(set.count) tracks")
            HarmonicTransitionStrip(camelots: set.map { $0.camelot })
        }
        .padding(.vertical, 4)

        List {
            ForEach(set, id: \.id) { t in
                let i = set.firstIndex(where: { $0.id == t.id }) ?? 0
                HStack(spacing: 10) {
                    Text("\(i + 1)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.tertiary)
                        .frame(width: 24, alignment: .trailing)
                    AlbumArtView(imageKey: t.imageKey, size: 40)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(t.title).lineLimit(1)
                        if let a = t.artist {
                            Text(a).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                    Spacer()
                    Text("\(Int(t.bpm)) BPM")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                    Badge(t.camelot, tint: .roonGold)
                }
                .padding(.vertical, 2)
                .accessibilityElement(children: .combine)
                .accessibilityLabel("\(i + 1). \(t.title)" + (t.artist.map { ", \($0)" } ?? "") + ", \(Int(t.bpm)) BPM, toonsoort \(t.camelot)")
            }
            .onMove { from, to in set.move(fromOffsets: from, toOffset: to) }
            .onDelete { indices in set.remove(atOffsets: indices) }
        }
        #if os(iOS)
        .environment(\.editMode, .constant(.active))
        #endif
        .listStyle(.plain)
        .scrollDisabled(true)
        .frame(minHeight: CGFloat(set.count) * 58)
    }

    private func build() {
        let tags = tagsText.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        Task {
            set = await client.buildDJSet(count: count, startBPM: startBPM, endBPM: endBPM, curve: curve, tags: tags)
            status = set.isEmpty ? "Geen tracks gevonden — verbreed het BPM-bereik of laat de tags weg." : nil
            if !set.isEmpty { Haptics.success() }
            if saveName.isEmpty { saveName = "DJ set \(Int(startBPM))–\(Int(endBPM)) BPM" }
        }
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
                Gradient(colors: [Color.roonWarning.opacity(0.30), Color.roonWarning.opacity(0.05)]),
                startPoint: CGPoint(x: 0, y: 0), endPoint: CGPoint(x: 0, y: size.height)))

            var line = Path()
            line.move(to: pt(0))
            for i in 1..<energies.count { line.addLine(to: pt(i)) }
            ctx.stroke(line, with: .color(Color.roonWarning), lineWidth: 2)
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
        case .sameKey:  .roonSuccess
        case .tempo:    .secondary.opacity(0.4)
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
            .accessibilityHidden(true)
            if !rels.isEmpty {
                Text("\(smooth)/\(rels.count) harmonische overgangen")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
    }
}
