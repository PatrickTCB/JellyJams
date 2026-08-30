import Foundation
import XCTest
@testable import JellyJams

@MainActor
final class LoadableModelTests: XCTestCase {
    func testANewModelHoldsItsInitialValueAndIsPending() {
        let model = LoadableModel([String]())

        XCTAssertTrue(model.value.isEmpty)
        XCTAssertFalse(model.isLoading)
        XCTAssertFalse(model.hasLoadedOnce)
        XCTAssertNil(model.errorMessage)
        XCTAssertTrue(model.isPending, "Nothing has been asked for yet, so a spinner is correct")
    }

    func testASuccessfulLoadPublishesItsValue() async {
        let model = LoadableModel([String]())

        await model.load { ["a", "b"] }

        XCTAssertEqual(model.value, ["a", "b"])
        XCTAssertTrue(model.hasLoadedOnce)
        XCTAssertFalse(model.isPending)
        XCTAssertNil(model.errorMessage)
    }

    /// An empty result is a completed load, not a pending one, so the screen
    /// can say "nothing here" instead of spinning forever.
    func testAnEmptyResultStopsPending() async {
        let model = LoadableModel([String]())

        await model.load { [] }

        XCTAssertTrue(model.value.isEmpty)
        XCTAssertTrue(model.hasLoadedOnce)
        XCTAssertFalse(model.isPending)
    }

    func testAFailedLoadReportsTheErrorAndKeepsTheLastValue() async {
        let model = LoadableModel([String]())
        await model.load { ["kept"] }

        await model.load { throw JellyfinError.notAuthenticated }

        XCTAssertEqual(model.value, ["kept"], "A failed refresh must not blank the screen")
        XCTAssertEqual(model.errorMessage, JellyfinError.notAuthenticated.errorDescription)
        XCTAssertTrue(model.hasLoadedOnce)
        XCTAssertFalse(model.isLoading)
    }

    func testRetryingAfterAFailureClearsTheError() async {
        let model = LoadableModel([String]())
        await model.load { throw JellyfinError.notAuthenticated }
        XCTAssertNotNil(model.errorMessage)

        await model.load { ["recovered"] }

        XCTAssertNil(model.errorMessage)
        XCTAssertEqual(model.value, ["recovered"])
    }

    /// A cancelled load means the view went away or its id changed. That is not
    /// a failure to report, and the next load must still run.
    func testACancelledLoadIsNotReportedAndLeavesTheScreenUnloaded() async {
        let model = LoadableModel([String]())

        let load = Task {
            await model.load {
                try await Task.sleep(for: .seconds(5))
                return ["late"]
            }
        }
        await Task.yield()
        load.cancel()
        await load.value

        XCTAssertNil(model.errorMessage)
        XCTAssertFalse(model.hasLoadedOnce, "The next load must still be allowed to run")
        XCTAssertFalse(model.isLoading)
        XCTAssertTrue(model.value.isEmpty)
    }

    /// The bug this guard exists for: a slow first request landing after a
    /// newer one and overwriting the results the user is actually looking at.
    func testASupersededLoadCannotOverwriteANewerOne() async throws {
        let model = LoadableModel([String]())

        let slow = Task {
            await model.load {
                try await Task.sleep(for: .milliseconds(200))
                return ["stale"]
            }
        }
        try await Task.sleep(for: .milliseconds(20))
        await model.load { ["fresh"] }
        XCTAssertEqual(model.value, ["fresh"])

        await slow.value

        XCTAssertEqual(model.value, ["fresh"])
        XCTAssertFalse(model.isLoading, "The superseded load must not clear a newer load's state")
    }

    /// A superseded *failure* is just as damaging: it would put an error banner
    /// over results that loaded fine.
    func testASupersededFailureCannotReportOverANewerSuccess() async throws {
        let model = LoadableModel([String]())

        let slow = Task {
            await model.load {
                try await Task.sleep(for: .milliseconds(200))
                throw JellyfinError.notAuthenticated
            }
        }
        try await Task.sleep(for: .milliseconds(20))
        await model.load { ["fresh"] }

        await slow.value

        XCTAssertNil(model.errorMessage)
        XCTAssertEqual(model.value, ["fresh"])
    }

    func testResetReturnsToTheInitialState() async {
        let model = LoadableModel([String]())
        await model.load { ["a"] }

        model.reset()

        XCTAssertTrue(model.value.isEmpty)
        XCTAssertFalse(model.hasLoadedOnce)
        XCTAssertFalse(model.isLoading)
        XCTAssertNil(model.errorMessage)
        XCTAssertTrue(model.isPending)
    }

    /// Clearing the search box while a search is in flight must not let that
    /// search's results appear afterwards.
    func testResetAbandonsALoadInFlight() async throws {
        let model = LoadableModel([String]())

        let slow = Task {
            await model.load {
                try await Task.sleep(for: .milliseconds(200))
                return ["abandoned"]
            }
        }
        try await Task.sleep(for: .milliseconds(20))
        model.reset()

        await slow.value

        XCTAssertTrue(model.value.isEmpty)
        XCTAssertFalse(model.hasLoadedOnce)
    }

    func testANonCollectionValueIsSupported() async {
        let model = LoadableModel(0)

        await model.load { 42 }

        XCTAssertEqual(model.value, 42)
        XCTAssertTrue(model.hasLoadedOnce)
    }
}
