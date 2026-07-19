import SwiftUI
import RoonSageCore

/// 2D scatter of every analyzed track: X = tempo, Y = energy, colour = Camelot
/// key. Click a point to play that track. A purely native, ML-free "map" built
/// from the analyzer's features.
@MainActor
public struct MusicMapView: View {
    public init() {}
    @Environment(RoonClient.self) private var client
    @State private var tracks: [DatabaseManager.SonicTrack] = []
    @State private var isLoading = false
    @State private var loaded = false
    @State private var selected: DatabaseManager.SonicTrack?
    /// Memoized once per data change — recomputing in `body` and on every tap made
    /// the scatter O(n) per render. Recomputed only in `load()`.
    @State private var bounds = Bounds([])
    /// Per-track normalized (0…1, y-up) map coordinates, index-aligned with
    /// `tracks`. Plot-independent, so they're computed once in `load()` and merely
    /// scaled into the plot at render — not recomputed per point per frame.
    @State private var norm: [CGPoint] = []
    /// Spatial index over `norm` so a tap resolves the nearest dot by checking only
    /// nearby grid cells (O(1) amortized) instead of scanning every track. Rebuilt
    /// only in `load()`, alongside `norm`.
    @State private var grid = SpatialGrid(points: [])

    public var body: some View {
        Group {
            if isLoading {
                ContentUnavailableView("Je bibliotheek in kaart brengen…", systemImage: "map")
            } else if tracks.isEmpty && loaded {
                ContentUnavailableView(
                    "Nog geen geanalyseerde tracks",
                    systemImage: "map",
                    description: Text("Draai de audio-analyzer en synchroniseer in Instellingen om je bibliotheek hier te plotten.")
                )
            } else {
                mapBody
            }
        }
        .navigationTitle("Music Map")
        .toolbar {
            Button { Task { await load(force: true) } } label: { Image(systemName: "arrow.clockwise") }
                .help("Ververs").disabled(isLoading)
        }
        .task { await load(force: false) }
    }

    private var mapBody: some View {
        VStack(spacing: Spacing.sm) {
            HStack {
                Text("\(tracks.count) geanalyseerde tracks")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text(usingMap ? "Sonische gelijkenis" : "Energie ↑   ·   Tempo →")
                    .font(.caption).foregroundStyle(.tertiary)
            }
            .padding(.horizontal, Spacing.lg)
            .padding(.top, Spacing.sm)

            colorLegend
                .padding(.horizontal, Spacing.lg)

            ZoneHintBanner()
                .padding(.horizontal, Spacing.lg)

            GeometryReader { geo in
                let pad: CGFloat = Spacing.xl
                let plot = CGRect(x: pad, y: pad,
                                  width: max(1, geo.size.width - pad * 2),
                                  height: max(1, geo.size.height - pad * 2))

                ZStack {
                    Canvas { ctx, _ in
                        // Frame
                        ctx.stroke(Path(plot), with: .color(.secondary.opacity(0.15)), lineWidth: 1)
                        for i in tracks.indices where i < norm.count {
                            let t = tracks[i]
                            let pt = position(norm[i], in: plot)
                            let isSel = t.id == selected?.id
                            let r: CGFloat = isSel ? 6 : 2.6
                            let rect = CGRect(x: pt.x - r, y: pt.y - r, width: r * 2, height: r * 2)
                            ctx.fill(Path(ellipseIn: rect),
                                     with: .color(color(for: t.camelot).opacity(isSel ? 1 : 0.7)))
                            if isSel {
                                ctx.stroke(Path(ellipseIn: rect.insetBy(dx: -2, dy: -2)),
                                           with: .color(.white), lineWidth: 1.5)
                            }
                        }
                    }
                    .gesture(
                        SpatialTapGesture().onEnded { value in
                            selectNearest(to: value.location, in: plot)
                        }
                    )

                    if let sel = selected {
                        // Put the card on the opposite half from the tapped point so
                        // it never covers the dot you just selected.
                        let p = position(normalized(sel, bounds: bounds), in: plot)
                        let cardAtTop = p.y > plot.midY
                        selectionCard(sel)
                            .position(x: min(max(p.x, plot.minX + 124), plot.maxX - 124),
                                      y: cardAtTop ? plot.minY + 44 : plot.maxY - 44)
                    }
                }
            }
            .background(.background.secondary, in: RoundedRectangle(cornerRadius: Radius.lg))
            .padding(.horizontal, Spacing.lg)
            .padding(.bottom, Spacing.lg)
        }
    }

    // MARK: - Colour legend

    /// Explains the colour encoding (every dot is tinted by its Camelot key) — the
    /// map was colour-coding silently with no key.
    private var colorLegend: some View {
        HStack(spacing: Spacing.sm) {
            Text("Kleur = toonsoort")
                .font(.caption2).foregroundStyle(.secondary)
            LinearGradient(
                colors: (0..<12).map { Color(hue: Double($0) / 12.0, saturation: 0.7, brightness: 0.9) },
                startPoint: .leading, endPoint: .trailing)
                .frame(width: 132, height: 8)
                .clipShape(Capsule())
                .accessibilityHidden(true)
            Text("1 → 12")
                .font(.caption2.monospacedDigit()).foregroundStyle(.tertiary)
            Spacer()
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Kleur van elk punt staat voor de toonsoort (Camelot 1 tot 12)")
    }

    // MARK: - Selection card

    @ViewBuilder
    private func selectionCard(_ t: DatabaseManager.SonicTrack) -> some View {
        HStack(spacing: Spacing.sm) {
            AlbumArtView(imageKey: t.imageKey, size: 36)
            VStack(alignment: .leading, spacing: 1) {
                Text(t.title).font(.caption.weight(.semibold)).lineLimit(1)
                Text(t.artist ?? "Onbekend").font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                HStack(spacing: 4) {
                    if let bpm = t.bpm, bpm > 0 { Text("\(Int(bpm)) BPM") }
                    if !t.camelot.isEmpty { Text(t.camelot) }
                }
                .font(.caption2.monospacedDigit()).foregroundStyle(.tertiary)
            }
            Button {
                guard let zone = client.selectedZone else { return }
                Task { await client.startTrackRadio(title: t.title, artist: t.artist, album: t.album, zoneID: zone.id) }
            } label: { Image(systemName: "dot.radiowaves.left.and.right").tappable44() }
            .buttonStyle(.borderless)
            .disabled(client.selectedZone == nil)
            .accessibilityLabel("Start station vanaf \(t.title)")
            .help(client.selectedZone == nil ? "Kies eerst een zone" : "Start een sonisch station vanaf deze plek op de kaart")
            Button {
                guard let zone = client.selectedZone else { return }
                Task { await client.playTrack(id: t.id, title: t.title, artist: t.artist, zoneID: zone.id) }
            } label: { Image(systemName: "play.fill").tappable44() }
            .buttonStyle(.borderless)
            .disabled(client.selectedZone == nil)
            .accessibilityLabel("Speel \(t.title)")
            .help(client.selectedZone == nil ? "Kies eerst een zone" : "Speel nu")
        }
        .frame(width: 240)
        .padding(Spacing.sm)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: Radius.lg))
        .overlay(RoundedRectangle(cornerRadius: Radius.lg).strokeBorder(.gray.opacity(0.2)))
        .shadow(color: .roonShadow, radius: 4)
        .transition(.scale.combined(with: .opacity))
    }

    // MARK: - Geometry

    private struct Bounds {
        var usingMap = false
        var xMin = 0.0, xMax = 1.0, yMin = 0.0, yMax = 1.0   // PCA ranges
        var bpmMin = 60.0, bpmMax = 180.0, eMin = 0.0, eMax = 1.0
        init(_ tracks: [DatabaseManager.SonicTrack]) {
            let mapped = tracks.filter { $0.mapX != nil && $0.mapY != nil }
            // Use the learned PCA map once a clear majority of tracks have coords.
            if mapped.count >= max(3, tracks.count / 2) {
                usingMap = true
                let xs = mapped.compactMap { $0.mapX }, ys = mapped.compactMap { $0.mapY }
                if let lo = xs.min(), let hi = xs.max(), hi > lo { xMin = lo; xMax = hi }
                if let lo = ys.min(), let hi = ys.max(), hi > lo { yMin = lo; yMax = hi }
            }
            let bpms = tracks.compactMap { $0.bpm }.filter { $0 > 0 }
            let es = tracks.compactMap { $0.energySignal }
            if let lo = bpms.min(), let hi = bpms.max(), hi > lo { bpmMin = lo; bpmMax = hi }
            if let lo = es.min(), let hi = es.max(), hi > lo { eMin = lo; eMax = hi }
        }
    }

    /// Plot-independent normalized (0…1, y-up) coordinate for a track — the learned
    /// PCA map when a majority of tracks have coords, else tempo×energy. Computed
    /// once per data load (see `norm`), then scaled into the plot by `position`.
    private func normalized(_ t: DatabaseManager.SonicTrack, bounds: Bounds) -> CGPoint {
        let bx: Double, ey: Double
        if bounds.usingMap, let mx = t.mapX, let my = t.mapY {
            bx = (mx - bounds.xMin) / max(0.001, bounds.xMax - bounds.xMin)
            ey = (my - bounds.yMin) / max(0.001, bounds.yMax - bounds.yMin)
        } else {
            bx = ((t.bpm ?? bounds.bpmMin) - bounds.bpmMin) / max(0.001, bounds.bpmMax - bounds.bpmMin)
            ey = ((t.energySignal ?? bounds.eMin) - bounds.eMin) / max(0.001, bounds.eMax - bounds.eMin)
        }
        return CGPoint(x: min(1, max(0, bx)), y: min(1, max(0, ey)))
    }

    /// Scale a normalized (0…1, y-up) point into the plot rect. Cheap — no bounds math.
    private func position(_ n: CGPoint, in plot: CGRect) -> CGPoint {
        CGPoint(x: plot.minX + n.x * plot.width, y: plot.maxY - n.y * plot.height)
    }

    private var usingMap: Bool { bounds.usingMap }

    private func selectNearest(to loc: CGPoint, in plot: CGRect) {
        guard plot.width > 0, plot.height > 0, !norm.isEmpty else { return }
        // Tap → normalized space, then query only the grid cells within the ~14pt
        // hit radius (padded to 20pt so the box strictly contains it) instead of
        // scanning every dot. The exact screen-distance test + threshold below is
        // unchanged, so selection is identical to the old O(n) scan.
        let nx = (loc.x - plot.minX) / plot.width
        let ny = (plot.maxY - loc.y) / plot.height
        let rx = 20 / plot.width
        let ry = 20 / plot.height
        var best: DatabaseManager.SonicTrack?
        var bestDist = CGFloat.greatestFiniteMagnitude
        for i in grid.candidates(x: nx, y: ny, rx: rx, ry: ry) where i < tracks.count {
            let p = position(norm[i], in: plot)
            let d = (p.x - loc.x) * (p.x - loc.x) + (p.y - loc.y) * (p.y - loc.y)
            if d < bestDist { bestDist = d; best = tracks[i] }
        }
        // Only select if reasonably close (≈14pt).
        withAnimation(Motion.quick) {
            selected = bestDist <= 196 ? best : nil
        }
    }

    /// Camelot number → hue around the wheel; minor (A) slightly darker.
    private func color(for camelot: String) -> Color {
        guard let letter = camelot.last, letter == "A" || letter == "B",
              let num = Int(camelot.dropLast()), (1...12).contains(num) else {
            return .gray.opacity(0.6)
        }
        let hue = Double(num - 1) / 12.0
        return Color(hue: hue, saturation: 0.7, brightness: letter == "A" ? 0.72 : 0.95)
    }

    private func load(force: Bool) async {
        if !tracks.isEmpty && !force { return }
        isLoading = true
        if force { await client.invalidateSonicCache() }
        var lib = await client.sonicLibrary()
        // Compute the PCA projection once when embeddings exist but coords don't
        // (or on an explicit refresh), then reload with the stored map_x/map_y.
        let hasEmbeddings = lib.contains { ($0.embedding?.count ?? 0) > 0 }
        let hasCoords = lib.contains { $0.mapX != nil }
        if hasEmbeddings && (!hasCoords || force) {
            _ = await client.computeMusicMap()
            lib = await client.sonicLibrary()
        }
        tracks = lib
        let b = Bounds(lib)
        bounds = b
        // Precompute normalized coords + the spatial index once per data change,
        // so render scales cheaply and taps hit-test against the grid, not O(n).
        let points = lib.map { normalized($0, bounds: b) }
        norm = points
        grid = SpatialGrid(points: points)
        isLoading = false
        loaded = true
    }
}
