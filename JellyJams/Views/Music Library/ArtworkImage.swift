import SwiftUI
import ImageIO

/// In-memory cache of decoded artwork. Thread-safe via `NSCache`.
///
/// Two key spaces live here: whole images under their URL alone — the Now
/// Playing lock-screen artwork and CarPlay, which want every pixel the server
/// sent — and images downsampled to a display bucket under the URL plus the
/// bucket, so list rows and tiles decode once and share the result.
final class ImageCache: @unchecked Sendable {
    static let shared = ImageCache()
    private let cache = NSCache<NSString, PlatformImage>()

    private init() {
        cache.countLimit = 500
    }

    func image(for url: URL) -> PlatformImage? { cache.object(forKey: url.cacheKey()) }
    func set(_ image: PlatformImage, for url: URL) { cache.setObject(image, forKey: url.cacheKey()) }

    func image(for url: URL, bucket: Int) -> PlatformImage? {
        cache.object(forKey: url.cacheKey(bucket: bucket))
    }

    func set(_ image: PlatformImage, for url: URL, bucket: Int) {
        cache.setObject(image, forKey: url.cacheKey(bucket: bucket))
    }
}

private extension URL {
    /// The cache key for this URL, namespaced by decode size when one is given.
    func cacheKey(bucket: Int? = nil) -> NSString {
        guard let bucket else { return absoluteString as NSString }
        return "\(absoluteString)#\(bucket)" as NSString
    }
}

enum ArtworkLoader {
    static let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.urlCache = URLCache(memoryCapacity: 32 * 1024 * 1024, diskCapacity: 512 * 1024 * 1024)
        config.requestCachePolicy = .returnCacheDataElseLoad
        return URLSession(configuration: config)
    }()
}

/// Reads and decodes artwork off the main actor, downsampled to the size it
/// will be displayed at.
///
/// Disk reads and image decoding are synchronous, and a `View`'s methods are
/// `@MainActor`-isolated, so decoding in the view would occupy the main actor
/// for every row appearing on screen. The work is dispatched to the global
/// executor instead, using `ImageIO`'s thumbnail API so a 500-pixel file
/// headed for a 40-point row decodes to the row's own bucket rather than full
/// size. `PlatformImage` is not formally `Sendable`, so it crosses back inside
/// an unchecked box — the same arrangement ``ImageCache`` relies on.
enum ArtworkDecoder {
    /// A decoded image in transit from the global executor back to the caller.
    /// It is freshly built from immutable pixel data and shared with no one,
    /// so the unchecked conformance holds.
    private struct DecodedArtwork: @unchecked Sendable {
        var image: PlatformImage?
    }

    static func decode(fileAt url: URL, maxPixelSize: Int) async -> PlatformImage? {
        await Task.detached(priority: .userInitiated) {
            DecodedArtwork(image: Self.thumbnail(
                from: CGImageSourceCreateWithURL(url as CFURL, nil),
                maxPixelSize: maxPixelSize
            ))
        }.value.image
    }

    static func decode(data: Data, maxPixelSize: Int) async -> PlatformImage? {
        await Task.detached(priority: .userInitiated) {
            DecodedArtwork(image: Self.thumbnail(
                from: CGImageSourceCreateWithData(data as CFData, nil),
                maxPixelSize: maxPixelSize
            ))
        }.value.image
    }

    /// Decodes the first image of `source` at `maxPixelSize` pixels on its
    /// longest side, with any stored rotation applied. A source smaller than
    /// `maxPixelSize` is not scaled up.
    private static func thumbnail(from source: CGImageSource?, maxPixelSize: Int) -> PlatformImage? {
        guard let source else { return nil }
        let options = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize
        ] as CFDictionary
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options) else { return nil }
        return PlatformImage(decodedCGImage: cgImage)
    }
}

/// Displays remote artwork with a memory + disk cache and a placeholder.
/// Falls back to a music-note glyph while loading or on failure.
/// If `localURL` is provided and the file exists, it's loaded directly (for
/// offline playback). Reading and decoding happen off the main actor, at the
/// size the view is displayed at.
struct ArtworkImage: View {
    let url: URL?
    var localURL: URL? = nil
    var cornerRadius: CGFloat = 6
    var placeholderSystemImage: String = "music.note"

    @State private var image: PlatformImage?
    @Environment(\.displayScale) private var displayScale

    /// What restarts the load: a different image, or the same image at a
    /// different decode resolution.
    private struct TaskKey: Equatable {
        var url: URL?
        var bucket: Int
    }

    var body: some View {
        GeometryReader { geo in
            let bucket = Self.pixelBucket(for: geo.size, scale: displayScale)
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
            .task(id: TaskKey(url: url, bucket: bucket)) {
                await load(bucket: bucket)
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }

    /// The decode resolution for artwork displayed at `size` on a screen with
    /// `scale` backing pixels per point: the longest side in pixels, snapped
    /// up to a power of two so views of slightly different sizes share one
    /// decoded copy, bounded to cover row thumbnails through full-screen
    /// player artwork.
    ///
    /// The scale is passed in rather than read from the environment — a pure
    /// function of its inputs — so the bucketing rule is directly testable.
    nonisolated static func pixelBucket(for size: CGSize, scale: CGFloat) -> Int {
        let displayedPixels = max(size.width, size.height) * max(scale, 1)
        var bucket: CGFloat = 128
        while bucket < displayedPixels && bucket < 2048 {
            bucket *= 2
        }
        return Int(bucket)
    }

    private func load(bucket: Int) async {
        image = nil
        // Local file first (for offline playback of downloaded artwork).
        if let localURL {
            if let cached = ImageCache.shared.image(for: localURL, bucket: bucket) {
                image = cached
                return
            }
            if let decoded = await ArtworkDecoder.decode(fileAt: localURL, maxPixelSize: bucket) {
                ImageCache.shared.set(decoded, for: localURL, bucket: bucket)
                image = decoded
                return
            }
            // Fall through to network load
        }
        guard let url else { return }
        if let cached = ImageCache.shared.image(for: url, bucket: bucket) {
            image = cached
            return
        }
        do {
            let (data, response) = try await ArtworkLoader.session.data(from: url)
            try Task.checkCancellation()
            guard let response = response as? HTTPURLResponse,
                  (200..<300).contains(response.statusCode),
                  let decoded = await ArtworkDecoder.decode(data: data, maxPixelSize: bucket)
            else { return }
            ImageCache.shared.set(decoded, for: url, bucket: bucket)
            image = decoded
        } catch {
            return
        }
    }
}
