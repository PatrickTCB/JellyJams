import Foundation

/// The state of one asynchronous read: the value, whether a load is in flight,
/// and any error worth showing the user.
///
/// ``PagedItems`` does this for browsable lists. Detail screens — an album's
/// tracks, an artist's overview, a genre's contents, search results — each used
/// to carry their own `isLoading`/`errorMessage` pair, their own copy of the
/// "a cancelled load is not a failure" rule, and their own guard against a
/// superseded response landing after a newer one. That is the same state
/// machine four times over, and a fifth every time a screen is added.
///
/// Views supply the work at call time, the way ``PagedItems/load(from:)`` does,
/// so this stays independent of how anything is fetched.
@MainActor
final class LoadableModel<Value>: ObservableObject {
    @Published private(set) var value: Value
    @Published private(set) var isLoading = false
    @Published private(set) var errorMessage: String?
    /// Whether a load has finished, successfully or not. This is what tells
    /// "there is nothing here" apart from "nothing has been asked for yet".
    @Published private(set) var hasLoadedOnce = false

    /// Whether a spinner is the right thing to show: nothing has arrived yet,
    /// or a retry is in flight.
    var isPending: Bool { isLoading || !hasLoadedOnce }

    private let initialValue: Value
    /// Identifies the load whose result is still wanted, so a response that has
    /// been superseded is dropped instead of overwriting a newer one.
    private var generation = UUID()

    init(_ initialValue: Value) {
        self.initialValue = initialValue
        self.value = initialValue
    }

    /// Runs `operation` and publishes its result, replacing any load already in
    /// flight.
    func load(_ operation: () async throws -> Value) async {
        let requestGeneration = UUID()
        generation = requestGeneration
        isLoading = true
        errorMessage = nil

        let outcome: Result<Value, Error>
        do {
            outcome = .success(try await operation())
        } catch {
            outcome = .failure(error)
        }

        guard requestGeneration == generation else { return }

        switch outcome {
        case .success(let loaded):
            value = loaded
            hasLoadedOnce = true
        case .failure(let error):
            // A cancelled load means the view was replaced or its id changed:
            // drop the spinner without reporting a failure the user didn't
            // cause, and leave `hasLoadedOnce` false so the next load runs.
            if !error.isCancellation {
                errorMessage = error.userFacingMessage
                hasLoadedOnce = true
            }
        }
        isLoading = false
    }

    /// Returns to the state before anything was loaded and abandons any load in
    /// flight. Used when the question itself goes away — an emptied search box
    /// has no results, not zero results.
    func reset() {
        generation = UUID()
        value = initialValue
        isLoading = false
        errorMessage = nil
        hasLoadedOnce = false
    }
}
