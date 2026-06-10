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
        Group {
            if let key = imageKey,
               let url = client.imageURL(forKey: key, size: Int(size * 2)) {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let image):
                        image
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                    default:
                        placeholder
                    }
                }
            } else {
                placeholder
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: r))
    }

    private var placeholder: some View {
        ZStack {
            RoundedRectangle(cornerRadius: cornerRadius ?? size * 0.12)
                .fill(.quaternary)
            Image(systemName: "music.note")
                .font(.system(size: size * 0.35))
                .foregroundStyle(.tertiary)
        }
    }
}
