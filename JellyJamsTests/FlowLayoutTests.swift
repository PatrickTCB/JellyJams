import CoreGraphics
import XCTest
@testable import JellyJams

/// The wrapping used by the genre chip rows. Packing is a pure function so the
/// rules can be checked without rendering: off-by-one spacing and an
/// over-wide subview are the classic ways a flow layout goes wrong.
final class FlowLayoutTests: XCTestCase {
    private func pack(
        _ widths: [CGFloat],
        availableWidth: CGFloat,
        spacing: CGFloat = 8
    ) -> [FlowLayout.Row] {
        FlowLayout.rows(
            of: widths.map { CGSize(width: $0, height: 20) },
            availableWidth: availableWidth,
            spacing: spacing
        )
    }

    func testChipsThatFitStayOnOneRow() {
        let rows = pack([40, 40, 40], availableWidth: 200)

        XCTAssertEqual(rows.map(\.indices), [[0, 1, 2]])
        XCTAssertEqual(rows[0].width, 40 * 3 + 8 * 2)
    }

    /// Spacing sits between chips and not after the last one, so three 40pt
    /// chips need exactly 136pt.
    func testSpacingIsCountedBetweenChipsOnly() {
        XCTAssertEqual(pack([40, 40, 40], availableWidth: 136).count, 1)
        XCTAssertEqual(pack([40, 40, 40], availableWidth: 135).count, 2)
    }

    func testAChipThatWouldOverflowStartsANewRow() {
        XCTAssertEqual(pack([60, 60, 60], availableWidth: 130).map(\.indices), [[0, 1], [2]])
    }

    /// A chip wider than the container gets a row to itself. Dropping it, or
    /// looping while it refuses to fit, would both be worse than overflowing.
    func testAChipWiderThanTheContainerGetsItsOwnRow() {
        XCTAssertEqual(pack([500, 40], availableWidth: 100).map(\.indices), [[0], [1]])
    }

    func testRowHeightIsTheTallestChipInThatRow() {
        let rows = FlowLayout.rows(
            of: [CGSize(width: 40, height: 20), CGSize(width: 40, height: 34)],
            availableWidth: 200,
            spacing: 8
        )

        XCTAssertEqual(rows.map(\.height), [34])
    }

    func testNoChipsProduceNoRows() {
        XCTAssertTrue(pack([], availableWidth: 200).isEmpty)
    }

    func testEveryChipIsPlacedExactlyOnce() {
        let widths: [CGFloat] = [30, 90, 45, 120, 60, 25]
        let placed = pack(widths, availableWidth: 160).flatMap(\.indices)

        XCTAssertEqual(placed.sorted(), Array(widths.indices))
        XCTAssertEqual(placed.count, Set(placed).count)
    }
}
