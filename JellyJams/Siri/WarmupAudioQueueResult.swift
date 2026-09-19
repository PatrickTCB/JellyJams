#if os(iOS)
import AppIntents

/// A marker result confirming the audio queue is primed, satisfying the
/// audio-domain warmup contract. It carries no payload.
@AppEntity(schema: .audio.warmupAudioQueueResult)
struct WarmupAudioQueueResult: TransientAppEntity {
    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "Warmup Audio Queue Result")
    }

    init() {}
}
#endif
