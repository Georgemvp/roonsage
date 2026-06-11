import SwiftUI
import CoreImage
import RoonSageCore

// Decoded-image cache for album art. AsyncImage re-fetches and re-decodes on
// every scroll; this keeps decoded images in an NSCache (thread-safe) and dedupes
// concurrent loads of the same URL so a fast-scrolling library list stays smooth.
public actor ImageCache {
    public static let shared = ImageCache()

    private let cache = NSCache<NSURL, PlatformImage>()
    private var inFlight: [URL: Task<PlatformImage?, Never>] = [:]

    private init() {
        cache.countLimit = 400
        // Bound the on-disk cache once per session, off the main thread.
        Task.detached(priority: .utility) { DiskImageCache.prune() }
    }

    /// Return a decoded image for `url`, loading + caching it if needed.
    /// Lookup order: in-memory NSCache → on-disk cache → Roon Core HTTP.
    /// Concurrent calls for the same URL share one load.
    public func image(for url: URL) async -> PlatformImage? {
        if let cached = cache.object(forKey: url as NSURL) { return cached }
        if let existing = inFlight[url] { return await existing.value }

        // Detached so the disk read + network fetch run off this actor's
        // executor — otherwise they'd serialise every image load.
        let task = Task.detached(priority: .userInitiated) { () -> PlatformImage? in
            if let data = DiskImageCache.data(for: url), let image = PlatformImage(data: data) {
                return image
            }
            guard let (data, _) = try? await URLSession.shared.data(from: url),
                  let image = PlatformImage(data: data) else { return nil }
            DiskImageCache.store(data, for: url)
            return image
        }
        inFlight[url] = task
        let image = await task.value
        inFlight[url] = nil
        if let image { cache.setObject(image, forKey: url as NSURL) }
        return image
    }

    private var colorCache: [URL: Color] = [:]

    /// Average ("dominant") colour of the art at `url`, for a tinted backdrop.
    /// Cached per URL; returns nil if the image can't be loaded/analysed.
    public func dominantColor(for url: URL) async -> Color? {
        if let cached = colorCache[url] { return cached }
        guard let image = await image(for: url), let ci = image.ciImageForAnalysis else { return nil }
        let params: [String: Any] = [kCIInputImageKey: ci,
                                     kCIInputExtentKey: CIVector(cgRect: ci.extent)]
        guard let output = CIFilter(name: "CIAreaAverage", parameters: params)?.outputImage else { return nil }
        var bitmap = [UInt8](repeating: 0, count: 4)
        let context = CIContext(options: [.workingColorSpace: NSNull()])
        context.render(output, toBitmap: &bitmap, rowBytes: 4,
                       bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
                       format: .RGBA8, colorSpace: CGColorSpaceCreateDeviceRGB())
        let color = Color(.sRGB,
                          red: Double(bitmap[0]) / 255, green: Double(bitmap[1]) / 255,
                          blue: Double(bitmap[2]) / 255, opacity: 1)
        colorCache[url] = color
        return color
    }
}

extension PlatformImage {
    /// A `CIImage` for analysis, regardless of platform bitmap type.
    var ciImageForAnalysis: CIImage? {
        #if os(macOS)
        guard let data = tiffRepresentation, let rep = NSBitmapImageRep(data: data) else { return nil }
        return CIImage(bitmapImageRep: rep)
        #else
        guard let cg = cgImage else { return nil }
        return CIImage(cgImage: cg)
        #endif
    }
}

/// Album-art view backed by `ImageCache` (memory cache + in-flight dedupe), with
/// a music-note placeholder. Drop-in replacement for the old AsyncImage version.
public struct CachedArtImage<Placeholder: View>: View {
    private let url: URL?
    private let placeholder: Placeholder
    @State private var image: PlatformImage?

    public init(url: URL?, @ViewBuilder placeholder: () -> Placeholder) {
        self.url = url
        self.placeholder = placeholder()
    }

    public var body: some View {
        Group {
            if let image {
                Image(platformImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                placeholder
            }
        }
        .task(id: url) {
            guard let url else { image = nil; return }
            image = await ImageCache.shared.image(for: url)
        }
    }
}
