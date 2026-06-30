import RoonSageCore
import SwiftUI

/// Reusable "play on this device" action: streams a track list through the
/// on-device engine (`RoonClient.playLocally`) so the iPhone — or Mac — acts as
/// the listening endpoint, independent of any Roon zone.
///
/// Unlike the Roon play buttons it is **not** gated on a selected zone — local
/// playback is always available when an analyzer server is reachable. Feedback
/// is global: the `LocalPlaybackBar` mini-player appears (and reports any
/// skipped Qobuz/stream-only tracks), and failures surface via the shared
/// `ActionErrorToast`. Callers only supply the track provider.
@MainActor
public struct LocalPlayButton: View {
    public enum Style { case icon, labeled }

    @Environment(RoonClient.self) private var client
    private let style: Style
    private let provider: () async -> [TrackRecord]
    @State private var busy = false

    /// - Parameters:
    ///   - style: `.icon` for an inline device glyph, `.labeled` for a titled button.
    ///   - tracks: async provider so callers with on-disk lists wrap trivially and
    ///     drill-downs can fetch their tracks lazily on tap.
    public init(style: Style = .icon, tracks: @escaping () async -> [TrackRecord]) {
        self.style = style
        self.provider = tracks
    }

    #if os(macOS)
    private static let deviceIcon = "laptopcomputer"
    private static let deviceNoun = "deze Mac"
    #else
    private static let deviceIcon = "iphone"
    private static let deviceNoun = "dit apparaat"
    #endif

    public var body: some View {
        Button {
            Haptics.tap()
            busy = true
            Task {
                let tracks = await provider()
                if !tracks.isEmpty { await client.playLocally(tracks) }
                busy = false
            }
        } label: {
            switch style {
            case .icon:
                Image(systemName: Self.deviceIcon)
            case .labeled:
                Label("Op \(Self.deviceNoun)", systemImage: Self.deviceIcon)
            }
        }
        .disabled(busy)
        .accessibilityLabel("Speel op \(Self.deviceNoun)")
        .help("Speel lokaal af op \(Self.deviceNoun)")
    }
}
