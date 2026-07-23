import SwiftUI
import RoonSageCore

/// Loads album art from the Roon HTTP image API.
/// Falls back to a music-note placeholder on missing key or network error.
public struct AlbumArtView: View {
    @Environment(RoonClient.self) private var client
    let imageKey: String?
    var size: CGFloat = 56
    var cornerRadius: CGFloat? = nil

    public init(imageKey: String?, size: CGFloat = 56, cornerRadius: CGFloat? = nil) {
        self.imageKey = imageKey
        self.size = size
        self.cornerRadius = cornerRadius
    }

    public var body: some View {
        let r = cornerRadius ?? size * 0.12
        let url = imageKey.flatMap { client.imageURL(forKey: $0, size: Int(size * 2)) }
        CachedArtImage(url: url) { placeholder }
            .frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: r))
    }

    private var placeholder: some View {
        ZStack {
            // A soft gold-tinted gradient reads as "artwork missing" far more
            // gracefully than a flat grey tile sitting next to real covers.
            RoundedRectangle(cornerRadius: cornerRadius ?? size * 0.12)
                .fill(LinearGradient(
                    colors: [Color.roonGold.opacity(0.22), Color.roonGold.opacity(0.06)],
                    startPoint: .topLeading, endPoint: .bottomTrailing))
            Image(systemName: "music.note")
                .font(.system(size: size * 0.34, weight: .semibold))
                .foregroundStyle(Color.roonGold.opacity(0.7))
        }
    }
}
