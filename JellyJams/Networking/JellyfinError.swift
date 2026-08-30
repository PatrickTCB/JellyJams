import Foundation

enum JellyfinError: LocalizedError, Sendable, Equatable {
    case invalidServerURL
    case notAuthenticated
    case incompleteAuthenticationResponse
    case missingItemIdentifier
    case invalidMediaURL
    case emptyPlaylistName
    case emptyCollection(String)

    var errorDescription: String? {
        switch self {
        case .invalidServerURL:
            return "The server address is not valid."
        case .notAuthenticated:
            return "You are not signed in."
        case .incompleteAuthenticationResponse:
            return "The server accepted the sign-in but did not return a complete user session."
        case .missingItemIdentifier:
            return "The server returned a media item without an identifier."
        case .invalidMediaURL:
            return "The SDK could not create a valid media URL."
        case .emptyPlaylistName:
            return "A playlist needs a name."
        case .emptyCollection(let name):
            return "“\(name)” doesn’t contain any songs."
        }
    }
}

extension Error {
    var userFacingMessage: String {
        (self as? LocalizedError)?.errorDescription ?? localizedDescription
    }

    /// Whether this error just means "the work was cancelled" rather than
    /// something the user needs to know about.
    ///
    /// A cancelled request surfaces as `URLError.cancelled` once it has been
    /// through `URLSession`, and only as `CancellationError` when the task was
    /// cancelled before it got that far. Both happen routinely in normal use —
    /// a `.task(id:)` re-running, a view going away, a search term changing —
    /// so both must be treated as "no result", never as a failure to report.
    var isCancellation: Bool {
        if self is CancellationError { return true }
        if let urlError = self as? URLError, urlError.code == .cancelled { return true }
        return false
    }
}
