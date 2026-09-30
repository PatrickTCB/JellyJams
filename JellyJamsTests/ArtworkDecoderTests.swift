import AppKit
import CoreGraphics
import ImageIO
import XCTest
@testable import JellyJams

/// ``ArtworkDecoder``: the point of the decode path is that artwork decodes
/// at the size it will be displayed at, off the main actor.
final class ArtworkDecoderTests: XCTestCase {
    func testDecodesDataDownsampledToTheRequestedSize() async {
        let image = await ArtworkDecoder.decode(data: Self.jpegData(side: 500), maxPixelSize: 128)

        XCTAssertEqual(image?.size.width ?? 0, 128, accuracy: 1)
        XCTAssertEqual(image?.size.height ?? 0, 128, accuracy: 1)
    }

    /// The thumbnail API must not invent pixels: a bucket larger than the
    /// source decodes at the source's own size.
    func testDoesNotUpscaleBeyondTheSource() async {
        let image = await ArtworkDecoder.decode(data: Self.jpegData(side: 300), maxPixelSize: 2048)

        XCTAssertEqual(image?.size.width ?? 0, 300, accuracy: 1)
    }

    func testDecodesFilesAndReturnsNilForMissingOnes() async throws {
        let existing = FileManager.default.temporaryDirectory
            .appending(path: "artwork-decoder-\(UUID().uuidString).jpg")
        try Self.jpegData(side: 300).write(to: existing)
        defer { try? FileManager.default.removeItem(at: existing) }

        let decoded = await ArtworkDecoder.decode(fileAt: existing, maxPixelSize: 256)
        XCTAssertEqual(decoded?.size.width ?? 0, 256, accuracy: 1)

        let missing = FileManager.default.temporaryDirectory
            .appending(path: "artwork-decoder-missing-\(UUID().uuidString).jpg")
        let result = await ArtworkDecoder.decode(fileAt: missing, maxPixelSize: 256)
        XCTAssertNil(result)
    }

    /// A file can carry "rotate this 90° to display" in its metadata; the
    /// decode must bake that in or rotated artwork renders sideways. A
    /// landscape file rotated a quarter turn decodes portrait, still capped
    /// at the requested bucket on its longest side.
    func testDecodingAppliesStoredRotation() async {
        let rotated = Self.jpegData(width: 200, height: 100, orientation: .right)

        let image = await ArtworkDecoder.decode(data: rotated, maxPixelSize: 128)

        XCTAssertEqual(image?.size.width ?? 0, 64, accuracy: 1)
        XCTAssertEqual(image?.size.height ?? 0, 128, accuracy: 1)
    }

    /// Undecodable bytes must come back nil — not crash — because that nil is
    /// what sends the local-file path on to the network instead.
    func testUndecodableDataReturnsNil() async {
        let truncatedHeader = Data([0xFF, 0xD8, 0xFF, 0xEE])
        let fromTruncated = await ArtworkDecoder.decode(data: truncatedHeader, maxPixelSize: 128)
        XCTAssertNil(fromTruncated)

        let fromEmpty = await ArtworkDecoder.decode(data: Data(), maxPixelSize: 128)
        XCTAssertNil(fromEmpty)
    }

    // MARK: - Helpers

    /// A square JPEG, like a downloaded artwork file.
    private static func jpegData(side: Int) -> Data {
        jpegData(width: side, height: side)
    }

    /// A solid-colour JPEG, optionally carrying a stored orientation.
    private static func jpegData(
        width: Int,
        height: Int,
        orientation: CGImagePropertyOrientation? = nil
    ) -> Data {
        let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.setFillColor(CGColor(red: 0.6, green: 0.3, blue: 0.9, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = context.makeImage()!

        let data = NSMutableData()
        let destination = CGImageDestinationCreateWithData(data, "public.jpeg" as CFString, 1, nil)!
        var properties: [CFString: Any] = [:]
        if let orientation {
            properties[kCGImagePropertyOrientation] = orientation.rawValue
        }
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        CGImageDestinationFinalize(destination)
        return data as Data
    }
}
