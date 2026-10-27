import Foundation
import SwiftUI

/// Drives the Jelly Jams Backend settings sheet.
///
/// The sheet's pattern, which every backend setting added later should
/// follow: opening it pings the backend, and the feature settings only take
/// input while that ping answers. The backend lives on a home LAN as often
/// as on the internet, so being unreachable must not hide the settings or
/// reset them — the state the app stored last time is shown, read-only,
/// beside the reason it could not ask better.
@MainActor
final class JellyJamsBackendSettingsModel: ObservableObject {
    /// Whether the backend can be talked to, and if so whether it knows who
    /// this device is yet. `unreachable` and `needsRegistration` both show
    /// remembered state and allow no edits; the difference is who has work
    /// to do — the network, or the Save button above.
    enum Connection: Equatable {
        case checking
        case unreachable(reason: String)
        case needsRegistration
        case online
    }

    @Published private(set) var connection: Connection = .checking
    /// A refused Family Blend change, shown until the next refresh or retry.
    @Published private(set) var familyBlendError: String?
    @Published private(set) var isApplyingFamilyBlendChange = false

    /// Whether the Family Blend switch takes input now: the backend is
    /// answering, it knows this account, and no change of its own is
    /// already in flight.
    var canEditFamilyBlend: Bool {
        connection == .online && !isApplyingFamilyBlendChange
    }

    /// The whole open-the-sheet ritual: ask the backend whether it lives,
    /// and when it does, ask it what it thinks of this account. The saved
    /// ``PreferencesStore/familyBlendJoined`` speaks until the answers
    /// arrive — it is the app's memory of the last one.
    ///
    /// `backend` is the client built from the saved address, nil when there
    /// is no address to build one from or the address will not parse;
    /// `addressText` is what the field holds either way, which is all the
    /// model needs to say *why* it is unreachable.
    func refresh(
        backend: JellyJamsBackend?,
        addressText: String,
        userID: String?,
        registered: Bool,
        preferences: PreferencesStore
    ) async {
        familyBlendError = nil
        connection = .checking

        guard let backend else {
            let trimmed = addressText.trimmingCharacters(in: .whitespacesAndNewlines)
            connection = .unreachable(reason: trimmed.isEmpty
                ? "No backend address has been saved yet. Add one above and press Save."
                : "The saved backend address is not valid. Correct it above and press Save.")
            return
        }
        do {
            try await backend.ping()
        } catch let error where error.isCancellation {
            return
        } catch {
            connection = .unreachable(reason: error.userFacingMessage)
            return
        }

        // The blend, like every feature setting, belongs to a backend
        // account — and registering is what creates one.
        guard registered, let userID else {
            connection = .needsRegistration
            return
        }

        connection = .online
        await refreshFamilyBlend(backend: backend, userID: userID, preferences: preferences)
    }

    /// Flip the Family Blend membership. The switch has already moved (this
    /// is a toggle, and toggles should answer immediately), so the saved
    /// state is written first and withdrawn if the backend disagrees — the
    /// backend's own answer, not the tap, is what the memory keeps.
    func setFamilyBlend(
        joined: Bool,
        backend: JellyJamsBackend?,
        userID: String?,
        preferences: PreferencesStore
    ) async {
        guard canEditFamilyBlend, let backend, let userID else { return }

        familyBlendError = nil
        isApplyingFamilyBlendChange = true
        preferences.familyBlendJoined = joined
        defer { isApplyingFamilyBlendChange = false }

        do {
            let answer = joined
                ? try await backend.joinFamilyBlend(userID: userID)
                : try await backend.leaveFamilyBlend(userID: userID)
            preferences.familyBlendJoined = answer.inFamilyBlend
        } catch let error where error.isCancellation {
            preferences.familyBlendJoined = !joined
        } catch {
            preferences.familyBlendJoined = !joined
            familyBlendError = error.userFacingMessage
        }
    }

    /// Asks the backend what it currently thinks of this account, and lets
    /// that answer replace the remembered one. A failure leaves the memory
    /// in place: the settings are still open and editable, and the switch
    /// shows the best truth the app has.
    private func refreshFamilyBlend(
        backend: JellyJamsBackend,
        userID: String,
        preferences: PreferencesStore
    ) async {
        do {
            let answer = try await backend.familyBlendStatus(userID: userID)
            preferences.familyBlendJoined = answer.inFamilyBlend
        } catch let error where error.isCancellation {
            return
        } catch {
            familyBlendError = error.userFacingMessage
        }
    }
}
