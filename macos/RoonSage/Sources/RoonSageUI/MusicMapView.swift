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

    public var body: some View {
        Group {
            if isLoading {
                ContentUnavailableView("Je bibliotheek in kaart brengen…", systemImage: "map")
            } else if tracks.isEmpty && loaded {
                ContentUnavailableView(
                    "No analyzed tracks yet",
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
                Text("\(tracks.count) analyzed tracks")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text("Energie ↑   ·   Tempo →")
                    .font(.caption).foregroundStyle(.tertiary)
            }
            .padding(.horizontal, Spacing.lg)
            .padding(.top, Spacing.sm)

            GeometryReader { geo in
                let bounds = Bounds(tracks)
                let pad: CGFloat = 24
                let plot = CGRect(x: pad, y: pad,
                                  width: max(1, geo.size.width - pad * 2),
                                  height: max(1, geo.size.height - pad * 2))

                ZStack {
                    Canvas { ctx, _ in
                        // Frame
                        ctx.stroke(Path(plot), with: .color(.gray.opacity(0.15)), lineWidth: 1)
                        for t in tracks {
                            let pt = position(t, in: plot, bounds: bounds)
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
                            selectNearest(to: value.location, in: plot, bounds: bounds)
                        }
                    )

                    if let sel = selected {
                        selectionCard(sel)
                            .position(x: plot.minX + 130, y: plot.minY + 42)
                    }
                }
            }
            .background(.background.secondary, in: RoundedRectangle(cornerRadius: Radius.lg))
            .padding(.horizontal, Spacing.lg)
            .padding(.bottom, Spacing.lg)
        }
    }

    // MARK: - Selection card

    @ViewBuilder
    private func selectionCard(_ t: DatabaseManager.SonicTrack) -> some View {
        HStack(spacing: Spacing.sm) {
            AlbumArtView(imageKey: t.imageKey, size: 36)
            VStack(alignment: .leading, spacing: 1) {
                Text(t.title).font(.caption.weight(.semibold)).lineLimit(1)
                Text(t.artist ?? "Unknown").font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                HStack(spacing: 4) {
                    if let bpm = t.bpm, bpm > 0 { Text("\(Int(bpm)) BPM") }
                    if !t.camelot.isEmpty { Text(t.camelot) }
                }
                .font(.caption2.monospacedDigit()).foregroundStyle(.tertiary)
            }
            Button {
                guard let zone = client.selectedZone else { return }
                Task { await client.playTrack(id: t.id, title: t.title, artist: t.artist, zoneID: zone.id) }
            } label: { Image(systemName: "play.fill") }
            .buttonStyle(.borderless)
            .disabled(client.selectedZone == nil)
        }
        .frame(width: 240)
        .padding(Spacing.sm)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.gray.opacity(0.2)))
        .shadow(radius: 4)
        .transition(.scale.combined(with: .opacity))
    }

    // MARK: - Geometry

    private struct Bounds {
        var bpmMin = 60.0, bpmMax = 180.0, eMin = 0.0, eMax = 1.0
        init(_ tracks: [DatabaseManager.SonicTrack]) {
            let bpms = tracks.compactMap { $0.bpm }.filter { $0 > 0 }
            let es = tracks.compactMap { $0.energy }
            if let lo = bpms.min(), let hi = bpms.max(), hi > lo { bpmMin = lo; bpmMax = hi }
            if let lo = es.min(), let hi = es.max(), hi > lo { eMin = lo; eMax = hi }
        }
    }

    private func position(_ t: DatabaseManager.SonicTrack, in plot: CGRect, bounds: Bounds) -> CGPoint {
        let bx = ((t.bpm ?? bounds.bpmMin) - bounds.bpmMin) / max(0.001, bounds.bpmMax - bounds.bpmMin)
        let ey = ((t.energy ?? bounds.eMin) - bounds.eMin) / max(0.001, bounds.eMax - bounds.eMin)
        return CGPoint(
            x: plot.minX + CGFloat(min(1, max(0, bx))) * plot.width,
            y: plot.maxY - CGFloat(min(1, max(0, ey))) * plot.height   // energy up
        )
    }

    private func selectNearest(to loc: CGPoint, in plot: CGRect, bounds: Bounds) {
        var best: DatabaseManager.SonicTrack?
        var bestDist = CGFloat.greatestFiniteMagnitude
        for t in tracks {
            let p = position(t, in: plot, bounds: bounds)
            let d = (p.x - loc.x) * (p.x - loc.x) + (p.y - loc.y) * (p.y - loc.y)
            if d < bestDist { bestDist = d; best = t }
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
        tracks = await client.sonicLibrary()
        isLoading = false
        loaded = true
    }
}
