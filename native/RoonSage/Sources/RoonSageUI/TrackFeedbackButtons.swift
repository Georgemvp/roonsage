import RoonSageCore
import SwiftUI

/// Compacte like/dislike-thumbs voor een resultaatrij. Schrijft naar dezelfde
/// server-of-record `track_feedback` als de Now Playing-duimen (`setFeedback`),
/// zodat élke curatie-surface (Genereer, Vraag het, …) de smaakvector voedt en
/// niet alleen Now Playing. Reflecteert de huidige stand via `feedbackFor`.
@MainActor
public struct TrackFeedbackButtons: View {
    @Environment(RoonClient.self) private var client
    private let title: String
    private let artist: String?
    private let album: String?

    public init(title: String, artist: String?, album: String?) {
        self.title = title
        self.artist = artist
        self.album = album
    }

    public var body: some View {
        let current = client.feedbackFor(title: title, artist: artist, album: album)
        HStack(spacing: Spacing.sm) {
            Button {
                Haptics.tap()
                Task { await client.setFeedback(.like, title: title, artist: artist, album: album) }
            } label: {
                Image(systemName: current == .like ? "hand.thumbsup.fill" : "hand.thumbsup")
                    .foregroundStyle(current == .like ? Color.roonGold : .secondary)
                    .contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Vind ik leuk: \(title)")

            Button {
                Haptics.tap()
                Task { await client.setFeedback(.dislike, title: title, artist: artist, album: album) }
            } label: {
                Image(systemName: current == .dislike ? "hand.thumbsdown.fill" : "hand.thumbsdown")
                    .foregroundStyle(current == .dislike ? Color.roonDanger : .secondary)
                    .contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Vind ik niet leuk: \(title)")
        }
        .font(.footnote)
    }
}
