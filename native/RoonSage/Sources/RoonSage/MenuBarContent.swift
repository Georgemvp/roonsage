import SwiftUI
import RoonSageCore
import RoonSageUI

@MainActor
struct MenuBarContent: View {
    @Environment(RoonClient.self) private var client

    private var activeZone: Zone? {
        client.selectedZone
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Now playing
            nowPlayingSection

            Divider()

            // Transport controls
            if let zone = activeZone {
                transportSection(zone: zone)
                Divider()
            }

            // Zone list (if > 1)
            if client.zones.count > 1 {
                zonePickerSection
                Divider()
            }

            // Status footer
            HStack(spacing: 6) {
                Circle()
                    .fill(client.connectionState.isConnected ? Color.roonSuccess : Color.roonDanger)
                    .frame(width: 6, height: 6)
                Text(client.connectionState.label)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .frame(width: 260)
    }

    // MARK: - Now playing

    @ViewBuilder
    var nowPlayingSection: some View {
        HStack(spacing: 10) {
            AlbumArtView(imageKey: activeZone?.nowPlaying?.imageKey, size: 44, cornerRadius: 8)

            VStack(alignment: .leading, spacing: 2) {
                if let np = activeZone?.nowPlaying {
                    Text(np.title)
                        .font(.subheadline.bold())
                        .lineLimit(1)
                    if let artist = np.artist {
                        Text(artist)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                } else if client.connectionState.isConnected {
                    Text("Er speelt niets")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                } else {
                    Text("Niet verbonden")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                if let zone = activeZone {
                    Text(zone.displayName)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }

            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    // MARK: - Transport

    func transportSection(zone: Zone) -> some View {
        HStack(spacing: 0) {
            Spacer()

            menuBarButton("backward.fill") {
                Task { await client.previous(zoneID: zone.id) }
            }

            menuBarButton(
                zone.state == .playing ? "pause.circle.fill" : "play.circle.fill",
                font: .title3,
                accent: true
            ) {
                Task { await client.playPause(zoneID: zone.id) }
            }

            menuBarButton("forward.fill") {
                Task { await client.next(zoneID: zone.id) }
            }

            Spacer()

            // Volume quick adjust
            if let output = zone.outputs.first, let vol = output.volume {
                menuBarButton(vol.isMuted ? "speaker.slash.fill" : "speaker.fill") {
                    Task { await client.toggleMute(outputID: output.id, muted: !vol.isMuted) }
                }
                menuBarButton("speaker.minus") {
                    Task { await client.adjustVolume(outputID: output.id, delta: -(vol.step > 0 ? vol.step : 2)) }
                }
                menuBarButton("speaker.plus") {
                    Task { await client.adjustVolume(outputID: output.id, delta: vol.step > 0 ? vol.step : 2) }
                }
            }

            Spacer()
        }
        .padding(.vertical, 6)
    }

    // MARK: - Zone picker

    var zonePickerSection: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Zones")
                .font(.caption2.uppercaseSmallCaps())
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 12)
                .padding(.top, 6)

            ForEach(client.zones) { zone in
                Button {
                    client.selectZone(zone.id)
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: zone.state.icon)
                            .font(.caption)
                            .foregroundStyle(zone.state == .playing ? Color.roonGold : .secondary)
                            .frame(width: 14)
                        Text(zone.displayName)
                            .font(.callout)
                        Spacer()
                        if client.selectedZone?.id == zone.id {
                            Image(systemName: "checkmark")
                                .font(.caption.bold())
                                .foregroundStyle(Color.roonGold)
                        }
                    }
                    .contentShape(Rectangle())
                    .padding(.horizontal, 12)
                    .padding(.vertical, 5)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.bottom, 4)
    }

    // MARK: - Helpers

    func menuBarButton(
        _ icon: String,
        font: Font = .callout,
        accent: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(font)
                .foregroundStyle(accent ? Color.roonGold : .primary)
                .frame(width: 32, height: 32)
        }
        .buttonStyle(.plain)
    }
}
