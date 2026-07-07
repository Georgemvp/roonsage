import RoonSageCore
import SwiftUI

/// Shared "Listen Now"-style shelf vocabulary: a cover model, a horizontal cover
/// shelf, a section header, a cover tile, and a stat card. Extracted verbatim from
/// `DiscoveryView` so the Ontdek dashboard and the Bibliotheek overview render from
/// one canonical set instead of drifting copies.
///
/// These are stateless on purpose — zone availability is passed in as `zoneAvailable`
/// rather than read from `@Environment`, so a tile can be previewed and reused from
/// any view without inheriting that view's playback plumbing.

/// A playable cover: the caller supplies both play actions (remote zone / on-device),
/// keeping playback semantics out of this shared layer.
public struct Cover: Identifiable {
    public let id: String
    public let title: String
    public let subtitle: String?
    public let imageKey: String?
    public let play: () -> Void
    public let playLocal: () -> Void

    public init(id: String, title: String, subtitle: String?, imageKey: String?,
                play: @escaping () -> Void, playLocal: @escaping () -> Void) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.imageKey = imageKey
        self.play = play
        self.playLocal = playLocal
    }
}

/// A section header: gold-tinted icon + title on the left, caller-supplied trailing
/// control (a shuffle button, "play all", or `EmptyView()`) on the right.
@MainActor @ViewBuilder
public func sectionHeader<Trailing: View>(
    _ title: String, _ icon: String, @ViewBuilder trailing: () -> Trailing
) -> some View {
    HStack {
        Label {
            Text(title).font(.headline).lineLimit(1)
        } icon: {
            Image(systemName: icon).foregroundStyle(Color.roonGold)
        }
        Spacer(minLength: Spacing.sm)
        trailing()
    }
}

/// A horizontal shelf: a `sectionHeader` above a horizontally scrolling row of
/// `coverTile`s. `zoneAvailable` gates the tiles' remote-play affordance.
@MainActor @ViewBuilder
public func shelf<Trailing: View>(
    _ title: String, _ icon: String, covers: [Cover], zoneAvailable: Bool,
    @ViewBuilder trailing: () -> Trailing
) -> some View {
    VStack(alignment: .leading, spacing: Spacing.sm) {
        sectionHeader(title, icon, trailing: trailing)
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .top, spacing: Spacing.md) {
                ForEach(covers) { coverTile($0, zoneAvailable: zoneAvailable) }
            }
            .padding(.horizontal, 2)
        }
    }
}

/// A single cover: artwork with a play badge, title, and subtitle. Tapping plays to
/// the active zone; the context menu offers remote / on-device playback.
@MainActor
public func coverTile(_ c: Cover, zoneAvailable: Bool) -> some View {
    Button {
        Haptics.tap()
        c.play()
    } label: {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            AlbumArtView(imageKey: c.imageKey, size: 130)
                .clipShape(RoundedRectangle(cornerRadius: Radius.md))
                .shadow(color: .roonShadow, radius: 4, y: 2)
                .overlay(alignment: .bottomTrailing) {
                    Image(systemName: "play.circle.fill")
                        .font(.title2)
                        .foregroundStyle(.white, Color.roonGold)
                        .shadow(radius: 3)
                        .padding(6)
                }
            Text(c.title).font(.caption.weight(.medium)).lineLimit(1)
            if let sub = c.subtitle {
                Text(sub).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .frame(width: 130)
    }
    .buttonStyle(.plain)
    .disabled(!zoneAvailable)
    .accessibilityLabel("Speel \(c.title)\(c.subtitle.map { " van \($0)" } ?? "")")
    .contextMenu {
        Button("Speel nu", systemImage: "play.fill") { Haptics.tap(); c.play() }
            .disabled(!zoneAvailable)
        Button("Speel op dit apparaat", systemImage: "iphone") { c.playLocal() }
    }
}

/// A compact metric tile: a big monospaced value over a caption label.
public struct StatCard: View {
    let label: String
    let value: String

    public init(label: String, value: String) {
        self.label = label
        self.value = value
    }

    public var body: some View {
        VStack(spacing: 4) {
            Text(value)
                .font(.title2.bold().monospacedDigit())
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 14)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: Radius.lg))
    }
}
