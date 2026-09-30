import CoreGraphics
import XCTest
@testable import JellyJams

/// ``ArtworkImage/pixelBucket(for:scale:)``: the decode resolution chosen for
/// a display size. It decides both how sharp artwork looks and how much
/// memory its decoded bitmaps hold, and its power-of-two snapping is what
/// lets rows of slightly different sizes share one decoded copy.
final class ArtworkImageTests: XCTestCase {
    // MARK: - Boundaries

    /// Row thumbnails and unmeasured geometry must never ask for less than
    /// 128 pixels: below that, album art starts looking soft.
    func testRowThumbnailsAndUnmeasuredGeometryFloorAt128() {
        XCTAssertEqual(ArtworkImage.pixelBucket(for: CGSize(width: 40, height: 40), scale: 1), 128)
        XCTAssertEqual(ArtworkImage.pixelBucket(for: CGSize(width: 40, height: 40), scale: 3), 128)
        // The view's geometry before layout settles.
        XCTAssertEqual(ArtworkImage.pixelBucket(for: .zero, scale: 2), 128)
    }

    func testFullScreenArtworkCapsAt2048() {
        XCTAssertEqual(ArtworkImage.pixelBucket(for: CGSize(width: 4000, height: 4000), scale: 3), 2048)
    }

    // MARK: - Snapping

    func testSizesSnapUpToPowersOfTwo() {
        // 200 pixels lands on 256, an exact power of two stays put, and one
        // pixel over crosses to the next bucket.
        XCTAssertEqual(ArtworkImage.pixelBucket(for: CGSize(width: 100, height: 100), scale: 2), 256)
        XCTAssertEqual(ArtworkImage.pixelBucket(for: CGSize(width: 256, height: 256), scale: 1), 256)
        XCTAssertEqual(ArtworkImage.pixelBucket(for: CGSize(width: 257, height: 257), scale: 1), 512)

        // A scale below one — an unset or degenerate environment value — is
        // treated as one rather than shrinking the bucket.
        XCTAssertEqual(ArtworkImage.pixelBucket(for: CGSize(width: 200, height: 200), scale: 0.5), 256)
        XCTAssertEqual(ArtworkImage.pixelBucket(for: CGSize(width: 200, height: 200), scale: 0), 256)
    }

    /// Artwork is square in practice, but the rule is stated for any shape:
    /// the longest side is the one that has to fit the bucket.
    func testTheLongestSideGoverns() {
        XCTAssertEqual(ArtworkImage.pixelBucket(for: CGSize(width: 320, height: 40), scale: 1), 512)
    }
}
