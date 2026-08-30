import SwiftUI

/// In-memory cache of decoded artwork, keyed by URL. Thread-safe via `NSCache`.
final class ImageCache: @unchecked Sendable {
    static let shared = ImageCache()
    private let cache = NSCache<NSURL, PlatformImage>()

    private init() {
        cache.countLimit = 500
    }

    func image(for url: URL) -> PlatformImage? { cache.object(forKey: url as NSURL) }
    func set(_ image: PlatformImage, for url: URL) { cache.setObject(image, forKey: url as NSURL) }
}

enum ArtworkLoader {
    static let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.urlCache = URLCache(memoryCapacity: 32 * 1024 * 1024, diskCapacity: 512 * 1024 * 1024)
        config.requestCachePolicy = .returnCacheDataElseLoad
        return URLSession(configuration: config)
    }()
}

/// Displays remote artwork with a memory + disk cache and a placeholder.
/// Falls back to a music-note glyph while loading or on failure.
struct ArtworkImage: View {
    let url: URL?
    var cornerRadius: CGFloat = 6
    var placeholderSystemImage: String = "music.note"

    @State private var image: PlatformImage?

    var body: some View {
        GeometryReader { geo in
            ZStack {
                if let image {
                    Image(platformImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } else {
                    ZStack {
                        Rectangle().fill(.quaternary)
                        Image(systemName: placeholderSystemImage)
                            .font(.system(size: min(geo.size.width, geo.size.height) * 0.32))
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .clipped()
        }
        .aspectRatio(1, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .task(id: url) { await load() }
    }

    private func load() async {
        image = nil
        guard let url else { return }
        if let cached = ImageCache.shared.image(for: url) {
            image = cached
            return
        }
        do {
            let (data, response) = try await ArtworkLoader.session.data(from: url)
            try Task.checkCancellation()
            guard let response = response as? HTTPURLResponse,
                  (200..<300).contains(response.statusCode),
                  let decoded = PlatformImage(data: data)
            else { return }
            ImageCache.shared.set(decoded, for: url)
            image = decoded
        } catch {
            return
        }
    }
}
