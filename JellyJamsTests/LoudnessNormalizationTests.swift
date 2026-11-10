import Foundation
import JellyfinAPI
import XCTest
@testable import JellyJams

/// The loudness normalization added against the server's measured audio level:
/// the gain the server reports for a track — or its album, when the track
/// carries none — and the linear multiplier that gain becomes before it rides
/// on top of the user's own volume at playback time.
final class LoudnessNormalizationTests: XCTestCase {
    // MARK: - Server-reported gain

    func testTheTrackCarriesItsOwnGain() {
        let track = BaseItemDto(id: "t", name: "Track", normalizationGain: 2.5, type: .audio)

        XCTAssertEqual(track.loudnessNormalizationGain, 2.5)
    }

    func testTheAlbumGainAppliesWhenTheTrackCarriesNone() {
        let track = BaseItemDto(albumNormalizationGain: -4, id: "t", name: "Track", type: .audio)

        XCTAssertEqual(track.loudnessNormalizationGain, -4)
    }

    func testNothingReportedMeansNoNormalization() {
        let track = BaseItemDto(id: "t", name: "Track", type: .audio)

        XCTAssertEqual(track.loudnessNormalizationGain, 0)
    }

    /// A negative gain means the track was measured loud and should come down,
    /// not up — the multiplier has to land below the neutral `1`.
    func testANegativeGainLowersTheTrackRatherThanRaisingIt() {
        let track = BaseItemDto(id: "t", name: "Track", normalizationGain: -3.5, type: .audio)

        XCTAssertEqual(track.loudnessNormalizationGain, -3.5)
    }

    // MARK: - Gain to multiplier

    /// No gain reported, or the feature off, means the neutral multiplier: the
    /// user's own volume is the whole level.
    func testNeutralGainHasNoMultiplier() {
        XCTAssertEqual(PlayerController.normalizationMultiplier(forGain: 0), 1, accuracy: 0.0001)
    }

    /// A positive gain is a volume lift: `+6` dB doubles the level, so the
    /// multiplier comes out just under `2`.
    func testAPositiveGainScalesTheVolumeUp() {
        XCTAssertEqual(
            PlayerController.normalizationMultiplier(forGain: 6),
            2,
            accuracy: 0.01,
            "A +6 dB gain doubles the level"
        )
    }

    /// A negative gain is a volume reduction: `-6` dB halves the level, so the
    /// multiplier comes out just over `0.5`.
    func testANegativeGainScalesTheVolumeDown() {
        XCTAssertEqual(
            PlayerController.normalizationMultiplier(forGain: -6),
            0.5,
            accuracy: 0.01,
            "A -6 dB gain halves the level"
        )
    }

    /// Fractional gains scale by the corresponding root of ten — `+3` dB is
    /// `10^(3/20)`.
    func testFractionalGainScalesByTheTenToTheTwentiethsPower() {
        XCTAssertEqual(PlayerController.normalizationMultiplier(forGain: 3), pow(10, 3.0 / 20), accuracy: 0.0001)
    }
}