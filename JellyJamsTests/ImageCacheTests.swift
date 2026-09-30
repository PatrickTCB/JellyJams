import CoreGraphics
import XCTest
@testable import JellyJams

/// ``ImageCache``: bucketed entries (``ArtworkImage`` rows and tiles) and
/// whole-image entries (the Now Playing lock screen and CarPlay, which want
/// every pixel the server sent) are separate key spaces over the same URL.
///
/// If they ever collide, a 128-pixel row decode replaces the full-size
/// artwork the system UI reads — the lock screen goes blurry. These tests
/// pin the separation down.
final class ImageCacheTests: XCTestCase {
    func testWholeImageAndBucketedEntriesDoNotCollide() {
        let url = uniqueURL()
        ImageCache.shared.set(Self.image(side: 300), for: url)
        ImageCache.shared.set(Self.image(side: 128), for: url, bucket: 128)

        XCTAssertEqual(ImageCache.shared.image(for: url)?.size.width ?? 0, 300, accuracy: 1)
        XCTAssertEqual(ImageCache.shared.image(for: url, bucket: 128)?.size.width ?? 0, 128, accuracy: 1)
    }

    /// One local artwork file serves rows, grid tiles and the player, which
    /// each decode at their own bucket; the buckets must not overwrite one
    /// another.
    func testDifferentBucketsKeepTheirOwnEntries() {
        let url = uniqueURL()
        ImageCache.shared.set(Self.image(side: 128), for: url, bucket: 128)
        ImageCache.shared.set(Self.image(side: 512), for: url, bucket: 512)

        XCTAssertEqual(ImageCache.shared.image(for: url, bucket: 128)?.size.width ?? 0, 128, accuracy: 1)
        XCTAssertEqual(ImageCache.shared.image(for: url, bucket: 512)?.size.width ?? 0, 512, accuracy: 1)
    }

    func testSettingTheSameKeyAgainReplacesItsEntry() {
        let url = uniqueURL()
        ImageCache.shared.set(Self.image(side: 128), for: url, bucket: 128)
        ImageCache.shared.set(Self.image(side: 64), for: url, bucket: 128)

        XCTAssertEqual(ImageCache.shared.image(for: url, bucket: 128)?.size.width ?? 0, 64, accuracy: 1)
    }

    // MARK: - Helpers

    /// URLs unique to this run, so neither the shared cache's existing
    /// contents nor these tests' entries can affect one another.
    private func uniqueURL() -> URL {
        URL(string: "https://example.com/artwork/\(UUID().uuidString).jpg")!
    }

    /// A solid-colour image, distinguishable from others by its size.
    private static func image(side: Int) -> PlatformImage {
        let context = CGContext(
            data: nil,
            width: side,
            height: side,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.8, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: side, height: side))
        return PlatformImage(decodedCGImage: context.makeImage()!)
    }
}
