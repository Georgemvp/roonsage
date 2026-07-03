import RoonSageCore
import SwiftUI

private typealias Cand = DatabaseManager.DJCandidate

/// Build a beatmatched, harmonically-mixed DJ set from analyzed audio features.
///
/// A live "mix plan" card previews the tempo arc before you build; the result is
/// presented like a pro DJ set — stat tiles, a combined tempo/energy flow chart,
/// and a tracklist that shows the harmonic transition quality between each pair.
///
/// Built on `List`/`Section` (not a custom `ScrollView`/`VStack`) — see
/// `GenerateView` for why.
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
    @State private var set: [Cand] = []
    @State private var saveName = ""
    @State private var status: String?
    @State private var building = false
    @State private var showRebuildConfirm = false
    // Loaded in .task — a DB read in `body` blocked main on every render.
    @State private var stats: (total: Int, matched: Int) = (0, 0)

    public var body: some View {
        List {
            if stats.matched == 0 {
                Section {
                    ContentUnavailableView {
                        Label("Nog geen geanalyseerde tracks", systemImage: "waveform.path.ecg")
                    } description: {
                        Text("Draai roonsage-analyzer op je muziek-host en synchroniseer daarna in Instellingen → Audio Analyzer.")
                    }
                    .listRowBackground(Color.clear)
                }
                .listRowSeparator(.hidden)
            } else {
                Section {
                    planCard
                        .listRowInsets(EdgeInsets(top: Spacing.sm, leading: Spacing.md,
                                                  bottom: Spacing.sm, trailing: Spacing.md))
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                }

                Section("Instellingen") {
                    Stepper("Tracks: \(count)", value: $count, in: 5...60, step: 5)

                    VStack(alignment: .leading, spacing: Spacing.xs) {
                        Text("Curve").font(.subheadline)
                        CurveSelector(selection: $curve)
                        Text(curve.blurb).font(.caption2).foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 2)

                    Stepper("Start: \(Int(startBPM)) BPM", value: $startBPM, in: 60...200, step: 1)
                    Stepper("Eind: \(Int(endBPM)) BPM", value: $endBPM, in: 60...200, step: 1)
                    HStack {
                        Text("Tags").foregroundStyle(.secondary)
                        TextField("optioneel, kommagescheiden (bijv. driving, deep house)", text: $tagsText)
                            .textFieldStyle(.roundedBorder)
                    }
                }

                Section("Zone") {
                    if !client.zones.isEmpty {
                        HStack {
                            Text("Afspelen op")
                            Spacer()
                            Picker("Zone", selection: $selectedZoneID) {
                                Text("Kies zone…").tag(Optional<String>.none)
                                ForEach(client.zones) { z in
                                    Label(z.displayName, systemImage: z.state.icon).tag(Optional(z.id))
                                }
                            }
                        }
                    }
                    Button {
                        if set.isEmpty { build() } else { showRebuildConfirm = true }
                    } label: {
                        HStack {
                            if building { ProgressView().controlSize(.small).tint(.black) }
                            Label(building ? "Bezig met mixen…" : "Bouw DJ-set",
                                  systemImage: "slider.horizontal.3")
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .tint(Color.roonGold)
                    .disabled(building)
                    .listRowBackground(Color.clear)
                    .confirmationDialog(
                        "Set opnieuw bouwen? De huidige set wordt vervangen.",
                        isPresented: $showRebuildConfirm, titleVisibility: .visible
                    ) {
                        Button("Opnieuw bouwen", role: .destructive) { build() }
                        Button("Annuleer", role: .cancel) {}
                    }
                    if let status { Text(status).font(.callout).foregroundStyle(.secondary) }
                }

                if !set.isEmpty { resultSections }
            }
        }
        .navigationTitle("DJ Set")
        .onAppear { if selectedZoneID == nil { selectedZoneID = client.selectedZone?.id } }
        .task { stats = await client.audioFeaturesStats() }
    }

    // MARK: - Mix plan (live preview before building)

    private var planCard: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            HStack {
                Label("Mixplan", systemImage: "waveform.path.ecg")
                    .font(.caption.weight(.medium)).foregroundStyle(.secondary)
                Spacer()
                Text(curve.label)
                    .font(.caption.weight(.semibold)).foregroundStyle(Color.roonGold)
                    .padding(.horizontal, Spacing.sm).padding(.vertical, 2)
                    .background(Color.roonGold.opacity(0.15), in: Capsule())
            }
            HStack(alignment: .firstTextBaseline, spacing: Spacing.sm) {
                Text("\(Int(startBPM))").font(.system(.largeTitle, design: .rounded).weight(.bold)).monospacedDigit()
                Image(systemName: "arrow.right").font(.headline).foregroundStyle(.secondary)
                Text("\(Int(endBPM))").font(.system(.largeTitle, design: .rounded).weight(.bold)).monospacedDigit()
                Text("BPM").font(.subheadline).foregroundStyle(.secondary).baselineOffset(2)
                Spacer()
            }
            BPMCurvePreview(bpms: DJSetBuilder.plannedBPM(start: startBPM, end: endBPM, count: count, curve: curve))
                .frame(height: 44)
                .accessibilityHidden(true)
            Text("\(count) tracks · \(stats.matched) beschikbaar")
                .font(.caption2).foregroundStyle(.secondary)
        }
        .padding(Spacing.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: Radius.lg).fill(.background.secondary)
                .overlay(RoundedRectangle(cornerRadius: Radius.lg).stroke(Color.roonGold.opacity(0.18), lineWidth: 1))
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Mixplan: \(Int(startBPM)) tot \(Int(endBPM)) BPM, \(curve.label), \(count) tracks")
    }

    // MARK: - Result

    private var setlistText: String {
        SetlistExport.text(
            name: saveName.trimmingCharacters(in: .whitespaces).isEmpty ? "DJ Set" : saveName,
            tracks: set.enumerated().map { i, c in
                .init(n: i + 1, title: c.title, artist: c.artist, bpm: c.bpm, camelot: c.camelot)
            })
    }

    @ViewBuilder
    private var resultSections: some View {
        // Stat tiles — the set at a glance.
        Section {
            VStack(spacing: Spacing.sm) {
                HStack(spacing: Spacing.sm) {
                    DJStatTile(label: "Gem. tempo", value: "\(avgBPM)", unit: "BPM")
                    DJStatTile(label: "Bereik", value: bpmRange, unit: "BPM")
                }
                HStack(spacing: Spacing.sm) {
                    DJStatTile(label: "Harmonisch", value: "\(harmonicCount)/\(max(0, set.count - 1))",
                               tint: .roonSuccess)
                    DJStatTile(label: "Artiesten", value: "\(uniqueArtists)", tint: .roonInfo)
                }
            }
            .listRowInsets(EdgeInsets(top: Spacing.sm, leading: Spacing.md,
                                      bottom: Spacing.sm, trailing: Spacing.md))
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
        } header: {
            Text("Set van \(set.count) tracks")
        }

        // Actions.
        Section {
            HStack {
                TextField("Naam playlist", text: $saveName).textFieldStyle(.roundedBorder)
                Button("Bewaar") {
                    let n = saveName.trimmingCharacters(in: .whitespaces)
                    guard !n.isEmpty else { return }
                    client.saveDJSet(name: n, set: set); status = "Playlist “\(n)” bewaard."
                }.disabled(saveName.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            HStack(spacing: Spacing.sm) {
                ShareLink(item: setlistText) {
                    Label("Exporteer", systemImage: "square.and.arrow.up").frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .help("Deel de setlist (met BPM en toonsoort)")

                Button {
                    guard let z = selectedZoneID else { return }
                    Haptics.tap()
                    Task { await client.playDJSet(set, zoneID: z) }
                } label: { Label("Speel", systemImage: "play.fill").frame(maxWidth: .infinity) }
                .buttonStyle(.borderedProminent).tint(Color.roonGold).disabled(selectedZoneID == nil)
                .help(selectedZoneID == nil ? "Kies eerst een zone" : "Speel de set af")
            }
        }

        // Set analysis: combined tempo/energy flow + harmonic transitions.
        Section("Analyse") {
            VStack(alignment: .leading, spacing: Spacing.md) {
                HStack {
                    Label("Tempo & energie", systemImage: "chart.xyaxis.line")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    LegendDot(color: .roonGold, text: "tempo")
                    LegendDot(color: .roonWarning, text: "energie")
                }
                SetFlowChart(bpms: mixBPMs, energies: set.map { $0.energy })
                    .frame(height: 72)
                    .accessibilityElement()
                    .accessibilityLabel("Tempo- en energieverloop over \(set.count) tracks, "
                        + "\(Int(mixBPMs.first ?? 0)) tot \(Int(mixBPMs.last ?? 0)) BPM")

                Divider().opacity(0.4)

                Label("Harmonische overgangen", systemImage: "point.topleft.down.to.point.bottomright.curvepath")
                    .font(.caption).foregroundStyle(.secondary)
                HarmonicTransitionStrip(camelots: set.map { $0.camelot })
            }
            .padding(.vertical, 4)
        }

        // Tracklist — DJ deck order with transition quality between pairs.
        Section("Tracks (\(set.count))") {
            let mix = mixBPMs
            ForEach(Array(set.enumerated()), id: \.element.id) { i, t in
                trackRow(index: i, track: t, mix: mix)
            }
            .onMove { from, to in set.move(fromOffsets: from, toOffset: to) }
            .onDelete { indices in set.remove(atOffsets: indices) }
        }
    }

    private func trackRow(index i: Int, track t: Cand, mix: [Double]) -> some View {
        let mixBPM = mix[safe: i] ?? t.bpm
        let octave = octaveLabel(raw: t.bpm, mix: mixBPM)
        // Precompute the label string; folding this ternary/optional chain into
        // the `.accessibilityLabel` modifier pushed the whole row over the
        // compiler's type-check budget on CI's (slower) toolchain.
        let a11y = "\(i + 1). \(t.title)" + (t.artist.map { ", \($0)" } ?? "")
            + ", \(Int(t.bpm)) BPM" + (octave != nil ? ", gemixt op \(Int(mixBPM))" : "")
            + ", toonsoort \(t.camelot)"
        return VStack(alignment: .leading, spacing: 6) {
            trackRowHeader(index: i, track: t, octave: octave)
            if i < set.count - 1 {
                transitionFooter(from: t, to: set[i + 1],
                                 mixFrom: mixBPM, mixTo: mix[safe: i + 1] ?? set[i + 1].bpm)
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(a11y)
    }

    /// The row's main line — split out of `trackRow` so each sub-expression
    /// type-checks quickly (the inline `Text + Text` concat plus the nested
    /// stacks were the slow part).
    @ViewBuilder
    private func trackRowHeader(index i: Int, track t: Cand, octave: String?) -> some View {
        HStack(spacing: 10) {
            Text("\(i + 1)")
                .font(.caption.monospacedDigit().weight(.medium))
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
            bpmText(t.bpm)
            if let octave {
                Text(octave)
                    .font(.caption2.weight(.semibold)).foregroundStyle(Color.roonInfo)
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background(Color.roonInfo.opacity(0.15), in: Capsule())
            }
            Badge(t.camelot.isEmpty ? "—" : t.camelot, tint: camelotColor(t.camelot))
        }
    }

    /// "<bpm> BPM" as a single explicitly-typed `Text` — the concatenation is
    /// the kind of expression Swift is slow to infer inside a big view builder.
    private func bpmText(_ bpm: Double) -> Text {
        Text("\(Int(bpm))").font(.callout.monospacedDigit().weight(.medium))
            + Text(" BPM").font(.caption2).foregroundColor(.secondary)
    }

    /// `×2` / `÷2` when a track is beatmatched at a different octave than its tag.
    private func octaveLabel(raw: Double, mix: Double) -> String? {
        guard raw > 0, abs(mix - raw) > 1 else { return nil }
        return mix > raw ? "×2" : "÷2"
    }

    /// The mix quality from this track into the next: tempo jump (at mix tempo) +
    /// key relation.
    private func transitionFooter(from a: Cand, to b: Cand, mixFrom: Double, mixTo: Double) -> some View {
        let delta = Int(mixTo.rounded()) - Int(mixFrom.rounded())
        let rel = RoonClient.harmonicRelation(current: a.camelot, candidate: b.camelot)
        let (relText, relColor): (String, Color) = {
            switch rel {
            case .harmonic: ("harmonische mix", .roonGold)
            case .sameKey:  ("zelfde toonsoort", .roonSuccess)
            case .tempo:    ("alleen tempo", .secondary)
            }
        }()
        let arrow = delta > 0 ? "arrow.up.right" : (delta < 0 ? "arrow.down.right" : "arrow.right")
        return HStack(spacing: 6) {
            Image(systemName: arrow)
            Text(delta == 0 ? "gelijk tempo" : "\(delta > 0 ? "+" : "−")\(abs(delta)) BPM").monospacedDigit()
            Text("·").foregroundStyle(.tertiary)
            Circle().fill(relColor).frame(width: 5, height: 5)
            Text(relText).foregroundStyle(relColor.opacity(0.9))
        }
        .font(.caption2)
        .foregroundStyle(.tertiary)
        .padding(.leading, 34)
        .accessibilityHidden(true)
    }

    // MARK: - Derived stats

    /// The per-track mix tempo (half/double-time folded) — what the chart, stats
    /// and transition deltas read from, so a beatmatched set curves smoothly.
    private var mixBPMs: [Double] { DJSetBuilder.mixTempos(set.map { $0.bpm }) }

    private var avgBPM: Int {
        let b = mixBPMs
        return b.isEmpty ? 0 : Int((b.reduce(0, +) / Double(b.count)).rounded())
    }
    private var bpmRange: String {
        let b = mixBPMs
        guard let lo = b.min(), let hi = b.max() else { return "—" }
        return "\(Int(lo))–\(Int(hi))"
    }
    private var harmonicCount: Int {
        guard set.count > 1 else { return 0 }
        return (0..<set.count - 1).filter {
            RoonClient.harmonicRelation(current: set[$0].camelot, candidate: set[$0 + 1].camelot) != .tempo
        }.count
    }
    private var uniqueArtists: Int { Set(set.compactMap { $0.artist }).count }

    private func build() {
        let tags = tagsText.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        building = true
        Task {
            let result = await client.buildDJSet(count: count, startBPM: startBPM, endBPM: endBPM, curve: curve, tags: tags)
            building = false
            set = result
            status = set.isEmpty ? "Geen tracks gevonden — verbreed het BPM-bereik of laat de tags weg." : nil
            if !set.isEmpty { Haptics.success() }
            if saveName.isEmpty { saveName = "DJ set \(Int(startBPM))–\(Int(endBPM)) BPM" }
        }
    }
}

// MARK: - Camelot colouring (matches the mix-radar wheel hues)

/// Colour a Camelot code by its wheel position so keys are recognisable at a
/// glance — the same hue mapping the Live-DJ radar uses.
private func camelotColor(_ code: String) -> Color {
    guard let letter = code.last, letter == "A" || letter == "B",
          let num = Int(code.dropLast()), (1...12).contains(num) else { return .roonGold }
    return Color(hue: Double(num - 1) / 12.0, saturation: 0.55, brightness: letter == "A" ? 0.82 : 0.98)
}

// MARK: - Curve selector

/// Four tappable cards showing the actual tempo shape of each curve, so picking
/// an arc is a visual choice rather than reading a dropdown label.
private struct CurveSelector: View {
    @Binding var selection: DJSetBuilder.Curve

    var body: some View {
        VStack(spacing: Spacing.sm) {
            HStack(spacing: Spacing.sm) { card(.flat); card(.rampUp) }
            HStack(spacing: Spacing.sm) { card(.rampDown); card(.peak) }
        }
    }

    private func card(_ c: DJSetBuilder.Curve) -> some View {
        let isSel = c == selection
        return Button {
            withAnimation(Motion.quick) { selection = c }
            Haptics.tap()
        } label: {
            HStack(spacing: Spacing.sm) {
                CurveGlyph(curve: c, active: isSel).frame(width: 34, height: 22)
                Text(c.label)
                    .font(.caption.weight(isSel ? .semibold : .regular))
                    .foregroundStyle(isSel ? Color.roonGold : .primary)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, Spacing.sm)
            .frame(maxWidth: .infinity, minHeight: 40)
            .background(
                RoundedRectangle(cornerRadius: Radius.md)
                    .fill(isSel ? Color.roonGold.opacity(0.12) : Color.secondary.opacity(0.08))
            )
            .overlay(
                RoundedRectangle(cornerRadius: Radius.md)
                    .stroke(isSel ? Color.roonGold.opacity(0.6) : .clear, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(c.label)
        .accessibilityAddTraits(isSel ? .isSelected : [])
    }
}

/// A tiny sparkline of a curve's normalised shape.
private struct CurveGlyph: View {
    let curve: DJSetBuilder.Curve
    let active: Bool

    var body: some View {
        Canvas { ctx, size in
            let vals = DJSetBuilder.plannedBPM(start: 0, end: 1, count: 24, curve: curve)
            guard vals.count > 1 else { return }
            let lo = vals.min() ?? 0, hi = vals.max() ?? 1
            let span = hi - lo
            let stepX = size.width / CGFloat(vals.count - 1)
            let inset: CGFloat = 3
            func pt(_ i: Int) -> CGPoint {
                let norm = span < 0.001 ? 0.5 : (vals[i] - lo) / span
                let y = inset + (1 - CGFloat(norm)) * (size.height - inset * 2)
                return CGPoint(x: CGFloat(i) * stepX, y: y)
            }
            var line = Path(); line.move(to: pt(0))
            for i in 1..<vals.count { line.addLine(to: pt(i)) }
            ctx.stroke(line, with: .color(active ? .roonGold : .secondary),
                       style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
        }
    }
}

// MARK: - Stat tile

private struct DJStatTile: View {
    let label: String
    let value: String
    var unit: String? = nil
    var tint: Color = .roonGold

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            Text(label.uppercased())
                .font(.caption2.weight(.semibold)).foregroundStyle(.secondary).tracking(0.5)
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(value)
                    .font(.system(.title3, design: .rounded).weight(.semibold)).monospacedDigit()
                    .foregroundStyle(tint)
                if let unit {
                    Text(unit).font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Spacing.md)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: Radius.lg))
    }
}

private struct LegendDot: View {
    let color: Color
    let text: String
    var body: some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(text).font(.caption2).foregroundStyle(.secondary)
        }
    }
}

// MARK: - Tempo / energy flow chart

/// A combined view of the set's journey: the energy arc as a filled backdrop
/// (fixed 0–1 scale, so build-ups read honestly) with the tempo drawn on top as
/// a gold line (auto-scaled), plus min/max BPM labels.
private struct SetFlowChart: View {
    let bpms: [Double]
    let energies: [Double]

    var body: some View {
        Canvas { ctx, size in
            guard bpms.count > 1 else { return }
            let n = bpms.count
            let stepX = size.width / CGFloat(n - 1)

            // Energy backdrop (0–1).
            func ept(_ i: Int) -> CGPoint {
                let e = min(1, max(0, energies[safe: i] ?? 0))
                return CGPoint(x: CGFloat(i) * stepX, y: size.height - CGFloat(e) * size.height)
            }
            var area = Path()
            area.move(to: CGPoint(x: 0, y: size.height))
            for i in 0..<n { area.addLine(to: ept(i)) }
            area.addLine(to: CGPoint(x: size.width, y: size.height))
            area.closeSubpath()
            ctx.fill(area, with: .linearGradient(
                Gradient(colors: [Color.roonWarning.opacity(0.28), Color.roonWarning.opacity(0.03)]),
                startPoint: .zero, endPoint: CGPoint(x: 0, y: size.height)))

            // Tempo line (auto-scaled).
            let lo = (bpms.min() ?? 0) - 2
            let hi = (bpms.max() ?? 1) + 2
            let span = max(1, hi - lo)
            func bpt(_ i: Int) -> CGPoint {
                CGPoint(x: CGFloat(i) * stepX, y: size.height - CGFloat((bpms[i] - lo) / span) * size.height)
            }
            var line = Path(); line.move(to: bpt(0))
            for i in 1..<n { line.addLine(to: bpt(i)) }
            ctx.stroke(line, with: .color(.roonGold),
                       style: StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))
            for i in 0..<n {
                let p = bpt(i)
                ctx.fill(Path(ellipseIn: CGRect(x: p.x - 2.5, y: p.y - 2.5, width: 5, height: 5)),
                         with: .color(.roonGold))
            }
            ctx.draw(Text("\(Int(hi)) BPM").font(.caption2).foregroundColor(.secondary),
                     at: CGPoint(x: 30, y: 9))
            ctx.draw(Text("\(Int(lo)) BPM").font(.caption2).foregroundColor(.secondary),
                     at: CGPoint(x: 30, y: size.height - 9))
        }
    }
}

// MARK: - Harmonic transitions

/// One pill per transition between consecutive tracks, coloured by how cleanly
/// the keys mix (gold = harmonic, green = same key, grey = tempo-only), with a
/// legend + summary so key clashes are obvious before you play the set.
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
        case .tempo:    .secondary.opacity(0.35)
        }
    }

    var body: some View {
        let rels = relations
        let smooth = rels.filter { $0 != .tempo }.count
        return VStack(alignment: .leading, spacing: Spacing.sm) {
            HStack(spacing: 3) {
                ForEach(Array(rels.enumerated()), id: \.offset) { _, r in
                    RoundedRectangle(cornerRadius: 2)
                        .fill(color(r))
                        .frame(height: 8)
                }
            }
            .accessibilityHidden(true)
            if !rels.isEmpty {
                HStack(spacing: Spacing.md) {
                    LegendDot(color: .roonGold, text: "harmonisch")
                    LegendDot(color: .roonSuccess, text: "zelfde toon")
                    Spacer()
                    Text("\(smooth)/\(rels.count) soepel")
                        .font(.caption2.weight(.medium)).foregroundStyle(.secondary)
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(smooth) van \(rels.count) overgangen mixen harmonisch")
    }
}

// MARK: - BPM plan preview

/// Sparkline of a tempo progression (used for the live mix-plan preview) so the
/// curve is visible at a glance, with min/max BPM labels.
private struct BPMCurvePreview: View {
    let bpms: [Double]

    var body: some View {
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
            var area = Path()
            area.move(to: CGPoint(x: 0, y: size.height))
            for i in 0..<bpms.count { area.addLine(to: pt(i)) }
            area.addLine(to: CGPoint(x: size.width, y: size.height))
            area.closeSubpath()
            ctx.fill(area, with: .color(Color.roonGold.opacity(0.15)))

            var line = Path()
            line.move(to: pt(0))
            for i in 1..<bpms.count { line.addLine(to: pt(i)) }
            ctx.stroke(line, with: .color(Color.roonGold),
                       style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))

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

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
