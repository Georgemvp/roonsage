import SwiftUI
import RoonSageCore

/// Built on `List` (used as a feed of self-styled cards via `.plainCardRow()`)
/// rather than a custom `ScrollView`/`VStack` — see `GenerateView` for why.
@MainActor
public struct SonicFingerprintView: View {
    public init() {}
    @Environment(RoonClient.self) private var client
    @State private var fingerprint: RoonClient.Fingerprint?
    @State private var isLoading = false
    @State private var loaded = false
    @State private var shareImage: Image?

    public var body: some View {
        List {
            if let fp = fingerprint {
                profileCard(fp).plainCardRow()
                if !fp.evolution.isEmpty { evolutionCard(fp).plainCardRow() }
                if !fp.cores.isEmpty { coresCard(fp).plainCardRow() }
                if !fp.recommendations.isEmpty { recommendationsCard(fp).plainCardRow() }
            } else if isLoading {
                Section {
                    ContentUnavailableView("Je sonische DNA berekenen…", systemImage: "waveform.path.ecg")
                        .listRowBackground(Color.clear)
                }
                .listRowSeparator(.hidden)
            } else if loaded {
                Section {
                    ContentUnavailableView(
                        "Nog geen geanalyseerde tracks",
                        systemImage: "waveform.path.ecg",
                        description: Text("Draai de audio-analyzer en synchroniseer in Instellingen, dan kan je muzikale DNA berekend worden.")
                    )
                    .listRowBackground(Color.clear)
                }
                .listRowSeparator(.hidden)
            }
        }
        .navigationTitle("Sonic DNA")
        .toolbar {
            if let shareImage {
                ShareLink(item: shareImage,
                          preview: SharePreview("Mijn Sonic DNA", image: shareImage)) {
                    Image(systemName: "square.and.arrow.up")
                }
                .help("Deel je sonische DNA")
            }
            Button { Task { await load(force: true) } } label: {
                Image(systemName: "arrow.clockwise")
            }
            .help("Herbereken")
            .disabled(isLoading)
        }
        .task { await load(force: false) }
    }

    // MARK: - Profile card (radar + stats)

    @ViewBuilder
    private func profileCard(_ fp: RoonClient.Fingerprint) -> some View {
        let p = fp.profile
        VStack(alignment: .leading, spacing: Spacing.md) {
            Text("Jouw muzikale DNA").font(.headline)
            // Spotify-Wrapped-achtige one-liner uit het profiel.
            Text(Self.personality(p))
                .font(.title2.bold())
                .foregroundStyle(Color.roonGold)
                .accessibilityLabel("Je muzikale persoonlijkheid: \(Self.personality(p))")
            Text(fp.usedHistory
                 ? "Gewogen naar je luistergeschiedenis — recente en veelgespeelde tracks tellen zwaarder (\(fp.seedCount) tracks)."
                 : "Nog geen luistergeschiedenis — dit profiel is een doorsnede van je bibliotheek.")
                .font(.caption).foregroundStyle(.secondary)

            // Wraps to a column on a narrow (iPhone) layout, stays side-by-side
            // on Mac/iPad — the old fixed 220+220 HStack overflowed on iPhone.
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .center, spacing: Spacing.xl) {
                    radar(p)
                    stats(p)
                    Spacer(minLength: 0)
                }
                VStack(alignment: .leading, spacing: Spacing.lg) {
                    radar(p).frame(maxWidth: .infinity)
                    stats(p)
                }
            }
        }
        .cardStyle()
    }

    private func radar(_ p: SonicDNA.Profile) -> some View {
        RadarChart(axes: p.axes)
            .frame(width: 240, height: 240)
    }

    private func stats(_ p: SonicDNA.Profile) -> some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            if p.avgBPM > 0 { statRow("Gem. tempo", "\(Int(p.avgBPM)) BPM") }
            statRow("Energie", percent(p.energy))
            statRow("Dansbaarheid", percent(p.danceability))
            statRow("Zonnigheid", percent(p.valence))
            statRow("Mainstream", percent(p.mainstream))
            if !p.topGenres.isEmpty {
                Text("Jouw genre-DNA").font(.caption).foregroundStyle(.secondary).padding(.top, Spacing.xs)
                DriftingTags(tags: p.topGenres.map { $0.name })
            }
            if !p.topMoods.isEmpty {
                Text("Stemming: " + p.topMoods.map { $0.name }.joined(separator: " · "))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: 260, alignment: .leading)
    }

    private func statRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).font(.callout).foregroundStyle(.secondary)
            Spacer()
            Text(value).font(.callout.monospacedDigit().weight(.medium))
        }
        .frame(maxWidth: 240)
    }

    /// One-line "personality" derived from the profile — playful but precise.
    static func personality(_ p: SonicDNA.Profile) -> String {
        let adj: String
        switch p.energy {
        case 0.66...:    adj = "Energieke"
        case 0.33..<0.66: adj = "Gebalanceerde"
        default:         adj = "Ingetogen"
        }
        let noun: String
        if p.mainstream <= 0.35 { noun = "deep-cut digger" }
        else if p.mainstream >= 0.65 { noun = "hitliefhebber" }
        else if p.adventure >= 0.55 { noun = "ontdekkingsreiziger" }
        else { noun = "fijnproever" }
        var line = "\(adj) \(noun)"
        if let genre = p.topGenres.first?.name {
            line += " met een hart voor \(genre.lowercased())"
        }
        return line
    }

    // MARK: - Evolution (recent window vs all-time)

    @ViewBuilder
    private func evolutionCard(_ fp: RoonClient.Fingerprint) -> some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            Text("Je DNA in beweging").font(.headline)
            Text("De laatste \(RoonClient.dnaRecentWindowDays) dagen vergeleken met je hele geschiedenis.")
                .font(.caption).foregroundStyle(.secondary)
            ForEach(fp.evolution, id: \.label) { d in
                HStack(spacing: Spacing.md) {
                    Image(systemName: d.delta > 0 ? "arrow.up.right" : "arrow.down.right")
                        .foregroundStyle(Color.roonGold)
                    Text(Self.evolutionText(d))
                        .font(.callout)
                    Spacer()
                    Text((d.delta > 0 ? "+" : "−") + percent(abs(d.delta)))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
        }
        .cardStyle()
    }

    /// "Energie ↑" → a human sentence per axis and direction.
    static func evolutionText(_ d: SonicDNA.AxisDelta) -> String {
        let up = d.delta > 0
        switch d.label {
        case "Energie":    return up ? "Je luistert energieker dan voorheen" : "Je luistert rustiger dan voorheen"
        case "Dansbaar":   return up ? "Meer dansbaars in je rotatie" : "Minder dansbaars in je rotatie"
        case "Zonnig":     return up ? "Je muziek klinkt zonniger" : "Je muziek klinkt melancholischer"
        case "Akoestisch": return up ? "Meer akoestisch en organisch" : "Meer elektronisch en geproduceerd"
        case "Avontuur":   return up ? "Avontuurlijker aan het luisteren" : "Dichter bij je vertrouwde smaak"
        case "Mainstream": return up ? "Meer bekende namen in je rotatie" : "Dieper in de deep cuts"
        default:           return "\(d.label) \(up ? "omhoog" : "omlaag")"
        }
    }

    // MARK: - Taste cores ("smaakkernen")

    @ViewBuilder
    private func coresCard(_ fp: RoonClient.Fingerprint) -> some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            Text("Jouw smaakkernen").font(.headline)
            Text("De plekken waar je luisteren écht leeft — elk met eigen aanbevelingen.")
                .font(.caption).foregroundStyle(.secondary)
            ForEach(fp.cores) { core in
                VStack(alignment: .leading, spacing: Spacing.sm) {
                    HStack(spacing: Spacing.sm) {
                        Text(core.label).font(.callout.weight(.semibold))
                        Badge(percent(core.share), tint: .roonGold)
                        Spacer(minLength: Spacing.sm)
                        if !core.recommendations.isEmpty {
                            Button {
                                play { await client.curateTracks(asTracks(core.recommendations), zoneID: $0) }
                            } label: {
                                Label("Speel", systemImage: "play.fill")
                            }
                            .buttonStyle(.bordered).controlSize(.small)
                            .disabled(client.selectedZone == nil)
                        }
                    }
                    if !core.topArtists.isEmpty {
                        Text(core.topArtists.joined(separator: " · "))
                            .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    ForEach(core.recommendations) { scored in
                        recommendationRow(scored, compact: true)
                    }
                }
                .padding(.vertical, Spacing.xs)
                if core.id != fp.cores.last?.id { Divider() }
            }
        }
        .cardStyle()
    }

    // MARK: - Recommendations

    @ViewBuilder
    private func recommendationsCard(_ fp: RoonClient.Fingerprint) -> some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            HStack {
                Text("Aanbevolen voor jou").font(.headline).lineLimit(1)
                Spacer(minLength: Spacing.sm)
                Button {
                    play { await client.curateTracks(asTracks(fp.recommendations), zoneID: $0) }
                } label: {
                    Label("Speel alles", systemImage: "play.fill")
                }
                .buttonStyle(.bordered).controlSize(.small)
                .disabled(client.selectedZone == nil)
                LocalPlayButton { asTracks(fp.recommendations) }
                    .buttonStyle(.bordered).controlSize(.small)
            }
            Text("Het dichtst bij jouw smaak, met ruimte voor ontdekking.")
                .font(.caption).foregroundStyle(.secondary)

            ForEach(fp.recommendations) { scored in
                recommendationRow(scored, compact: false)
            }
        }
        .cardStyle()
    }

    @ViewBuilder
    private func recommendationRow(_ scored: SonicEngine.Scored, compact: Bool) -> some View {
        HStack(spacing: Spacing.md) {
            AlbumArtView(imageKey: scored.track.imageKey, size: compact ? 32 : 40)
            VStack(alignment: .leading, spacing: 2) {
                Text(scored.track.title).font(.callout).lineLimit(1)
                Text(scored.track.artist ?? "Onbekend")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                if !compact, let reason = scored.reason {
                    Label(reason.text, systemImage: reasonIcon(reason.kind))
                        .font(.caption2)
                        .foregroundStyle(Color.roonGold.opacity(0.9))
                        .lineLimit(1)
                }
            }
            Spacer()
            if !compact {
                Text(percent(scored.similarity))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
            Button {
                let t = scored.track
                Haptics.tap()
                play { await client.playTrack(id: t.id, title: t.title, artist: t.artist, zoneID: $0) }
            } label: {
                Image(systemName: "play.fill")
            }
            .buttonStyle(.borderless)
            .disabled(client.selectedZone == nil)
            .accessibilityLabel("Speel nu")
            .help("Speel nu")
        }
    }

    // MARK: - Helpers

    private func asTracks(_ scored: [SonicEngine.Scored]) -> [TrackRecord] {
        scored.map { TrackRecord(id: $0.track.id, title: $0.track.title, artist: $0.track.artist, album: $0.track.album) }
    }

    private func percent(_ v: Double) -> String { "\(Int((v * 100).rounded()))%" }

    /// SF Symbol for a recommendation reason.
    private func reasonIcon(_ kind: RadioEngine.Reason.Kind) -> String {
        switch kind {
        case .similar:   return "waveform"
        case .favorite:  return "hand.thumbsup.fill"
        case .genre:     return "guitars"
        case .discovery: return "sparkles"
        }
    }

    private func play(_ action: @escaping (String) async -> Void) {
        guard let zone = client.selectedZone else { return }
        Task { await action(zone.id) }
    }

    private func load(force: Bool) async {
        if fingerprint != nil && !force { return }
        isLoading = true
        if force { await client.invalidateSonicCache() }
        let fp = await client.sonicFingerprint()
        fingerprint = fp
        isLoading = false
        loaded = true
        if let fp { renderShareImage(fp) }
    }

    /// Snapshot a self-contained share card to a sharable image. The radar is
    /// rendered statically (no TimelineView) so the snapshot isn't a half-way
    /// animation frame.
    private func renderShareImage(_ fp: RoonClient.Fingerprint) {
        let card = FingerprintShareCard(
            profile: fp.profile,
            headline: Self.personality(fp.profile),
            coreLabels: fp.cores.prefix(3).map { $0.label })
        let renderer = ImageRenderer(content: card)
        renderer.scale = 3
        if let cg = renderer.cgImage {
            shareImage = Image(decorative: cg, scale: 3)
        }
    }
}

// MARK: - Radar chart (animated, breathing)

private struct RadarChart: View {
    /// (label, value 0…1)
    let axes: [(String, Double)]
    var animated: Bool = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var start: Date?

    private var roonAmber: Color { Color(red: 0.80, green: 0.34, blue: 0.05) }

    var body: some View {
        Group {
            if animated && !reduceMotion {
                TimelineView(.animation) { timeline in
                    let elapsed = start.map { timeline.date.timeIntervalSince($0) } ?? 0
                    // Vertices spring out from the centre, then a gentle breath.
                    let p = Self.easeOutBack(min(1, elapsed / 0.9))
                    let breath = 1 + 0.025 * sin(elapsed * 1.3)
                    canvas(progress: p, breath: breath)
                }
                .onAppear { if start == nil { start = Date() } }
            } else {
                canvas(progress: 1, breath: 1)
            }
        }
        .accessibilityElement()
        .accessibilityLabel(axes.map { "\($0.0) \(Int(($0.1 * 100).rounded())) procent" }.joined(separator: ", "))
    }

    private func canvas(progress: Double, breath: Double) -> some View {
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

            // Data polygon — radius scaled by spring progress + breath.
            var shape = Path()
            var vertices: [CGPoint] = []
            for i in 0..<n {
                let v = max(0, min(1, axes[i].1)) * progress * breath
                let pt = point(center: center, radius: radius * CGFloat(v), index: i, count: n)
                vertices.append(pt)
                if i == 0 { shape.move(to: pt) } else { shape.addLine(to: pt) }
            }
            shape.closeSubpath()
            ctx.fill(shape, with: .radialGradient(
                Gradient(colors: [Color.roonGold.opacity(0.50), roonAmber.opacity(0.12)]),
                center: center, startRadius: 0, endRadius: radius))
            ctx.stroke(shape, with: .color(.roonGold), lineWidth: 2)

            // Vertex dots.
            for pt in vertices {
                let dot = Path(ellipseIn: CGRect(x: pt.x - 2.5, y: pt.y - 2.5, width: 5, height: 5))
                ctx.fill(dot, with: .color(.roonGold))
            }

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

    /// Ease-out with a slight overshoot so vertices "spring" past then settle.
    static func easeOutBack(_ t: Double) -> Double {
        let c1 = 1.70158, c3 = 1.70158 + 1
        let x = t - 1
        return 1 + c3 * x * x * x + c1 * x * x
    }
}

// MARK: - Drifting tag row (staggered fade-in)

private struct DriftingTags: View {
    let tags: [String]
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var shown = false

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 60), spacing: 6, alignment: .leading)],
                  alignment: .leading, spacing: 6) {
            ForEach(Array(tags.enumerated()), id: \.offset) { i, tag in
                Badge(tag, tint: .roonGold)
                    .opacity(shown || reduceMotion ? 1 : 0)
                    .offset(y: shown || reduceMotion ? 0 : 6)
                    .animation(reduceMotion ? nil : Motion.spring.delay(Double(i) * 0.05), value: shown)
            }
        }
        .frame(maxWidth: 260, alignment: .leading)
        .onAppear { shown = true }
    }
}

// MARK: - Shareable card

private struct FingerprintShareCard: View {
    let profile: SonicDNA.Profile
    let headline: String
    let coreLabels: [String]

    var body: some View {
        VStack(spacing: Spacing.lg) {
            Text("SONIC DNA")
                .font(.caption.weight(.bold))
                .tracking(4)
                .foregroundStyle(.secondary)
            Text(headline)
                .font(.title.bold())
                .foregroundStyle(Color.roonGold)
                .multilineTextAlignment(.center)
            RadarChart(axes: profile.axes, animated: false)
                .frame(width: 280, height: 280)
            if !profile.topGenres.isEmpty {
                Text(profile.topGenres.prefix(5).map { $0.name }.joined(separator: "  ·  "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if !coreLabels.isEmpty {
                Text("Smaakkernen: " + coreLabels.joined(separator: " · "))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Text("RoonSage")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(Color.roonGold.opacity(0.8))
        }
        .padding(36)
        .frame(width: 380)
        .background(Color.black)
    }
}
