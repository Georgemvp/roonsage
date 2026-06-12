import RoonSageCore
import SwiftUI

/// Live DJ mode — while a track plays, surface the library tracks that mix into
/// it best right now (Camelot-harmonic + tempo-matched). The hero is a Camelot
/// "mix radar": the playing track sits at the centre, candidates orbit at their
/// wheel position, sized by tempo match and coloured by key. The full list
/// remains below for detail and VoiceOver.
@MainActor
public struct LiveDJView: View {
    public init() {}
    @Environment(RoonClient.self) private var client

    @State private var suggestions: [DatabaseManager.DJCandidate] = []
    @State private var currentBPM: Double = 0
    @State private var currentCamelot: String = ""
    @State private var loading = false
    @State private var hasFeatures = true

    public var body: some View {
        Group {
            if let zone = client.selectedZone, let np = zone.nowPlaying {
                ScrollView {
                    VStack(alignment: .leading, spacing: Spacing.lg) {
                        currentCard(np)

                        if loading && suggestions.isEmpty {
                            SkeletonRows(count: 8)
                        } else if !hasFeatures {
                            noFeaturesNote
                        } else if suggestions.isEmpty {
                            Text("Geen compatibele tracks gevonden in dit tempo.")
                                .font(.callout).foregroundStyle(.secondary)
                        } else {
                            MixRadar(
                                currentBPM: currentBPM,
                                currentCamelot: currentCamelot,
                                currentImageKey: np.imageKey,
                                suggestions: suggestions,
                                onPlay: { c in
                                    Haptics.tap()
                                    Task { await client.curateTracks([asRecord(c)], zoneID: zone.id) }
                                },
                                onQueue: { c in
                                    Haptics.tap()
                                    Task { await client.queueTracks([asRecord(c)], next: true, zoneID: zone.id) }
                                }
                            )

                            Divider()
                            header
                            ForEach(suggestions, id: \.id) { row($0, zoneID: zone.id) }
                        }
                    }
                    .padding()
                }
                .task(id: np.title) { await reload(np) }
            } else {
                ContentUnavailableView("Niets aan het spelen",
                    systemImage: "slider.horizontal.2.gobackward",
                    description: Text("Start een track in een zone om harmonische vervolgsuggesties te zien."))
            }
        }
        .navigationTitle("Live DJ")
    }

    // MARK: Now-playing card

    private func currentCard(_ np: NowPlaying) -> some View {
        HStack(spacing: Spacing.md) {
            AlbumArtView(imageKey: np.imageKey, size: 72)
            VStack(alignment: .leading, spacing: 4) {
                Text("Nu spelend").font(.caption).foregroundStyle(.secondary)
                Text(np.title).font(.headline).lineLimit(1)
                if let artist = np.artist {
                    Text(artist).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                }
                HStack(spacing: Spacing.sm) {
                    if currentBPM > 0 { Badge("\(Int(currentBPM)) BPM") }
                    if !currentCamelot.isEmpty { Badge(currentCamelot, tint: .roonGold) }
                }
                .padding(.top, 2)
            }
            Spacer()
        }
    }

    private var header: some View {
        HStack {
            Text("Mixt hierna goed").font(.headline)
            Spacer()
            if loading { ProgressView().controlSize(.small) }
        }
    }

    private var noFeaturesNote: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Geen audio-kenmerken voor deze track", systemImage: "waveform.slash")
                .font(.callout)
            Text("Synchroniseer audio-kenmerken (Instellingen → Audio Analyzer) om harmonische suggesties te krijgen.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }

    // MARK: Suggestion row

    private func row(_ c: DatabaseManager.DJCandidate, zoneID: String) -> some View {
        let relation = RoonClient.harmonicRelation(current: currentCamelot, candidate: c.camelot)
        return HStack(spacing: Spacing.md) {
            AlbumArtView(imageKey: c.imageKey, size: 44)
            VStack(alignment: .leading, spacing: 2) {
                Text(c.title).font(.callout).lineLimit(1)
                if let artist = c.artist {
                    Text(artist).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                HStack(spacing: Spacing.xs) {
                    Badge("\(Int(c.bpm)) BPM")
                    if !c.camelot.isEmpty { Badge(c.camelot) }
                    relationBadge(relation)
                }
            }
            Spacer()
            Button {
                Haptics.tap()
                Task { await client.queueTracks([asRecord(c)], next: true, zoneID: zoneID) }
            } label: { Image(systemName: "text.line.first.and.arrowtriangle.forward") }
                .buttonStyle(.borderless)
                .accessibilityLabel("Als volgende in wachtrij")
                .help("Als volgende in wachtrij")
            Button {
                Haptics.tap()
                Task { await client.curateTracks([asRecord(c)], zoneID: zoneID) }
            } label: { Image(systemName: "play.fill") }
                .buttonStyle(.borderless)
                .accessibilityLabel("Speel nu")
                .help("Speel nu")
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private func relationBadge(_ relation: RoonClient.HarmonicRelation) -> some View {
        switch relation {
        case .harmonic: Badge("Harmonisch", tint: .roonGold)
        case .sameKey:  Badge("Zelfde toon", tint: .roonSuccess)
        case .tempo:    EmptyView()
        }
    }

    // MARK: Data

    private func asRecord(_ c: DatabaseManager.DJCandidate) -> TrackRecord {
        TrackRecord(id: c.id, title: c.title, artist: c.artist, album: c.album)
    }

    private func reload(_ np: NowPlaying) async {
        loading = true
        defer { loading = false }
        guard let feat = client.featuresFor(title: np.title, artist: np.artist, album: np.album),
              feat.bpm > 0 else {
            hasFeatures = false
            currentBPM = 0; currentCamelot = ""; suggestions = []
            return
        }
        hasFeatures = true
        currentBPM = feat.bpm
        currentCamelot = feat.camelot
        suggestions = await client.harmonicNextTracks(bpm: feat.bpm, camelot: feat.camelot, limit: 30)
    }
}

// MARK: - Camelot mix radar

@MainActor
private struct MixRadar: View {
    let currentBPM: Double
    let currentCamelot: String
    let currentImageKey: String?
    let suggestions: [DatabaseManager.DJCandidate]
    let onPlay: (DatabaseManager.DJCandidate) -> Void
    let onQueue: (DatabaseManager.DJCandidate) -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulse = false
    @State private var selectedID: String?

    private struct Placed: Identifiable {
        let id: String
        let candidate: DatabaseManager.DJCandidate
        let point: CGPoint
        let dotSize: CGFloat
        let compatible: Bool
    }

    private var compatibleSet: Set<String> { Self.compatibleCodes(currentCamelot) }

    var body: some View {
        VStack(spacing: Spacing.md) {
            GeometryReader { geo in
                let side = min(geo.size.width, geo.size.height)
                let center = CGPoint(x: geo.size.width / 2, y: geo.size.height / 2)
                let placed = layout(center: center, radius: side / 2 - 36)

                ZStack {
                    WheelCanvas(currentCamelot: currentCamelot, compatible: compatibleSet)

                    // Neon-gold harmonic arcs to compatible candidates.
                    Canvas { ctx, _ in
                        for p in placed where p.compatible {
                            var path = Path()
                            path.move(to: center)
                            path.addLine(to: p.point)
                            ctx.stroke(path, with: .color(.roonGold.opacity(reduceMotion ? 0.3 : (pulse ? 0.45 : 0.22))),
                                       lineWidth: 1.5)
                        }
                    }

                    // Centre: the playing track.
                    centreArt.position(center)

                    // Orbiting candidates.
                    ForEach(placed) { p in
                        candidateDot(p).position(p.point)
                    }
                }
            }
            .frame(height: 320)
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.easeInOut(duration: 1.2).repeatForever(autoreverses: true)) { pulse = true }
            }

            if let sel = suggestions.first(where: { $0.id == selectedID }) {
                actionBar(sel)
            } else {
                Text("Tik op een orbit om te mixen")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var centreArt: some View {
        AlbumArtView(imageKey: currentImageKey, size: 70)
            .clipShape(Circle())
            .overlay(Circle().stroke(Color.roonGold, lineWidth: 3))
            .shadow(color: .roonGold.opacity(0.4), radius: 10)
            .accessibilityHidden(true)
    }

    private func candidateDot(_ p: Placed) -> some View {
        let isSelected = selectedID == p.id
        let scale: CGFloat = isSelected ? 1.2 : (p.compatible && !reduceMotion && pulse ? 1.06 : 1.0)
        return Button {
            withAnimation(Motion.spring) { selectedID = p.id }
            Haptics.tap()
        } label: {
            AlbumArtView(imageKey: p.candidate.imageKey, size: p.dotSize)
                .clipShape(Circle())
                .overlay(
                    Circle().stroke(isSelected ? Color.roonGold
                                    : (p.compatible ? Color.roonGold.opacity(0.8) : .clear),
                                    lineWidth: isSelected ? 3 : 2)
                )
                .shadow(color: p.compatible ? .roonGold.opacity(0.5) : .clear, radius: p.compatible ? 6 : 0)
        }
        .buttonStyle(.plain)
        .opacity(p.compatible || isSelected ? 1 : 0.5)
        .scaleEffect(scale)
        .accessibilityLabel("\(p.candidate.title), \(Int(p.candidate.bpm)) BPM, \(p.candidate.camelot)")
    }

    private func actionBar(_ c: DatabaseManager.DJCandidate) -> some View {
        HStack(spacing: Spacing.md) {
            AlbumArtView(imageKey: c.imageKey, size: 40)
            VStack(alignment: .leading, spacing: 2) {
                Text(c.title).font(.callout).lineLimit(1)
                HStack(spacing: Spacing.xs) {
                    Badge("\(Int(c.bpm)) BPM")
                    if !c.camelot.isEmpty { Badge(c.camelot, tint: .roonGold) }
                }
            }
            Spacer()
            Button { onQueue(c) } label: { Image(systemName: "text.line.first.and.arrowtriangle.forward") }
                .buttonStyle(.bordered).controlSize(.small)
                .accessibilityLabel("Als volgende in wachtrij")
            Button { onPlay(c) } label: { Label("Speel nu", systemImage: "play.fill") }
                .buttonStyle(.borderedProminent).controlSize(.small)
        }
        .padding(Spacing.md)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: Radius.lg))
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }

    // MARK: Layout math

    private func layout(center: CGPoint, radius: CGFloat) -> [Placed] {
        var perSlot: [String: Int] = [:]
        var result: [Placed] = []
        for c in suggestions.prefix(16) {
            guard let angle = Self.slotAngle(c.camelot) else { continue }
            let isMinor = c.camelot.last == "A"
            let baseR = radius * (isMinor ? 0.60 : 0.92)
            let k = perSlot[c.camelot, default: 0]
            perSlot[c.camelot] = k + 1
            if k >= 3 { continue }   // cap overlap per wheel slot
            let r = baseR - CGFloat(k) * 26
            let pt = CGPoint(x: center.x + r * cos(angle), y: center.y + r * sin(angle))
            let dBPM = abs(c.bpm - currentBPM)
            let match = max(0, 1 - dBPM / 12)
            let dotSize = 30 + 22 * match
            let rel = RoonClient.harmonicRelation(current: currentCamelot, candidate: c.camelot)
            result.append(Placed(id: c.id, candidate: c, point: pt, dotSize: dotSize, compatible: rel != .tempo))
        }
        return result
    }

    static func slotAngle(_ camelot: String) -> Double? {
        guard let last = camelot.last, last == "A" || last == "B",
              let num = Int(camelot.dropLast()), (1...12).contains(num) else { return nil }
        return -.pi / 2 + 2 * .pi * Double(num - 1) / 12
    }

    /// Same logic as AudioAnalysis.Camelot.compatible, replicated so the UI
    /// target doesn't need to import the analyzer module.
    static func compatibleCodes(_ code: String) -> Set<String> {
        guard let last = code.last, last == "A" || last == "B",
              let num = Int(code.dropLast()), (1...12).contains(num) else { return [] }
        let letter = String(last)
        let other = letter == "A" ? "B" : "A"
        let plus1 = (num % 12) + 1
        let minus1 = ((num - 2 + 12) % 12) + 1
        return ["\(num)\(letter)", "\(num)\(other)", "\(plus1)\(letter)", "\(minus1)\(letter)"]
    }
}

// MARK: - Wheel backdrop

private struct WheelCanvas: View {
    let currentCamelot: String
    let compatible: Set<String>

    var body: some View {
        Canvas { ctx, size in
            let center = CGPoint(x: size.width / 2, y: size.height / 2)
            let radius = min(size.width, size.height) / 2 - 36

            // Two faint guide rings (inner = minor/A, outer = major/B).
            for factor in [0.60, 0.92] {
                let r = radius * factor
                let ring = Path(ellipseIn: CGRect(x: center.x - r, y: center.y - r, width: r * 2, height: r * 2))
                ctx.stroke(ring, with: .color(.gray.opacity(0.15)), lineWidth: 1)
            }

            // 12 numbered slots × 2 rings, coloured by Camelot hue, dimmed
            // unless the key is the current one or harmonically compatible.
            for num in 1...12 {
                let angle = -.pi / 2 + 2 * .pi * Double(num - 1) / 12
                for (letter, factor) in [("A", 0.60), ("B", 0.92)] {
                    let code = "\(num)\(letter)"
                    let r = radius * factor
                    let pt = CGPoint(x: center.x + r * cos(angle), y: center.y + r * sin(angle))
                    let isCurrent = code == currentCamelot
                    let isCompat = compatible.contains(code)
                    let base = Self.hue(code)
                    let opacity = isCurrent ? 1.0 : (isCompat ? 0.7 : 0.20)
                    let dotR: CGFloat = isCurrent ? 7 : 5
                    let marker = Path(ellipseIn: CGRect(x: pt.x - dotR, y: pt.y - dotR, width: dotR * 2, height: dotR * 2))
                    ctx.fill(marker, with: .color(base.opacity(opacity)))
                    if isCurrent {
                        let ring = Path(ellipseIn: CGRect(x: pt.x - 10, y: pt.y - 10, width: 20, height: 20))
                        ctx.stroke(ring, with: .color(.roonGold), lineWidth: 2)
                    }
                }
            }
        }
    }

    static func hue(_ camelot: String) -> Color {
        guard let letter = camelot.last, letter == "A" || letter == "B",
              let num = Int(camelot.dropLast()), (1...12).contains(num) else { return .gray }
        return Color(hue: Double(num - 1) / 12.0, saturation: 0.7, brightness: letter == "A" ? 0.72 : 0.95)
    }
}
