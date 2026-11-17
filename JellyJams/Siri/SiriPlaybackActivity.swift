#if os(tvOS)
import Intents
import SwiftUI

/// Receives classic-Siri playback requests on tvOS.
///
/// The JellyJamsSiri extension resolves a pass-through item and answers
/// `.continueInApp`, so the request arrives here as a user activity — on a
/// cold launch as much as while the app is already on screen. The snapshot
/// is taken synchronously (the intent objects are not `Sendable`), then the
/// shared pipeline answers it in the app's own process, where the session
/// and player live.
///
/// Failures surface as an alert hosted on the root view, the same place the
/// app's other outlived-their-screen errors come home: on TV the app is
/// already foregrounded by the hand-off, so the screen is where the person
/// is looking. Success needs no dialog — the music starting is the answer.
private struct SiriPlaybackActivityHandler: ViewModifier {
    @State private var failureMessage: String?

    func body(content: Content) -> some View {
        content
            .onContinueUserActivity(SiriMediaRequest.activityType) { activity in
                let request = SiriMediaRequest(activity: activity)
                Task { @MainActor in
                    if case .failure(let message) = await MediaIntentHandler.play(request) {
                        failureMessage = message
                    }
                }
            }
            .alert(
                "Siri Playback",
                isPresented: Binding(
                    get: { failureMessage != nil },
                    set: { if !$0 { failureMessage = nil } }
                )
            ) {
                Button("OK", role: .cancel) { failureMessage = nil }
            } message: {
                Text(failureMessage ?? "")
            }
    }
}

extension View {
    /// Answers the Siri extension's playback hand-offs. Hosted once, on the
    /// root view, so a request lands whichever screen is showing.
    func siriPlaybackRequests() -> some View {
        modifier(SiriPlaybackActivityHandler())
    }
}
#endif
