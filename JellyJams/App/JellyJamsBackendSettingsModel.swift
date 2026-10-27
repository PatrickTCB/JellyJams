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
    /// A refused limits save, shown until the next refresh or retry. The
    /// typed numbers stay put beside it — the address above keeps a failed
    /// registration's text for the same reason: fixing it should not mean
    /// retyping everything.
    @Published private(set) var limitsError: String?
    @Published private(set) var isApplyingLimitsChange = false

    /// Whether the Family Blend switch takes input now: the backend is
    /// answering, it knows this account, and no change of its own is
    /// already in flight.
    var canEditFamilyBlend: Bool {
        connection == .online && !isApplyingFamilyBlendChange
    }

    /// Whether the mixtape-limit steppers and their Save take input now:
    /// the same gate as the Family Blend switch, counting the limits' own
    /// change in flight rather than the blend's.
    var canEditLimits: Bool {
        connection == .online && !isApplyingLimitsChange
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
        limitsError = nil
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
        await refreshLimits(backend: backend, userID: userID, preferences: preferences)
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

    /// Save the mixtape limits the steppers settled on. The pair is one
    /// setting — the backend's `/limits` always takes both numbers — so
    /// Save sends what both steppers show together. Like the address
    /// above, a refused save keeps the typed numbers where they can be
    /// fixed and retried; the backend's own answer, not the tap, is what
    /// the memory keeps, and the next refresh replaces the draft with it
    /// if this save never agreed.
    func setLimits(
        backend: JellyJamsBackend?,
        userID: String?,
        preferences: PreferencesStore
    ) async {
        guard canEditLimits, let backend, let userID else { return }

        limitsError = nil
        isApplyingLimitsChange = true
        defer { isApplyingLimitsChange = false }

        do {
            let answer = try await backend.setLimits(
                userID: userID,
                sameAlbumLimit: preferences.sameAlbumLimit,
                sameArtistLimit: preferences.sameArtistLimit
            )
            preferences.sameAlbumLimit = answer.sameAlbumLimit
            preferences.sameArtistLimit = answer.sameArtistLimit
        } catch let error where error.isCancellation {
            return
        } catch {
            limitsError = error.userFacingMessage
        }
    }

    /// Asks the backend what limits it currently keeps for this account,
    /// and lets that answer replace the remembered one — including for a
    /// draft a refused Save left behind, which this is what corrects. The
    /// same grace as the blend's refresh: a failure leaves the memory in
    /// place and says why beside the steppers.
    private func refreshLimits(
        backend: JellyJamsBackend,
        userID: String,
        preferences: PreferencesStore
    ) async {
        do {
            let answer = try await backend.limits(userID: userID)
            preferences.sameAlbumLimit = answer.sameAlbumLimit
            preferences.sameArtistLimit = answer.sameArtistLimit
        } catch let error where error.isCancellation {
            return
        } catch {
            limitsError = error.userFacingMessage
        }
    }
}
