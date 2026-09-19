#if os(iOS)
import AppIntents

/// Playback modifiers the system passes along with a play request, so a
/// person can say "Play X shuffled" or "Play X on repeat".
@AppEnum(schema: .audio.playbackAttributes)
enum PlaybackAttributes: String {
    case shuffle
    case `repeat`

    static let caseDisplayRepresentations: [PlaybackAttributes: DisplayRepresentation] = [
        .shuffle: DisplayRepresentation(title: "Shuffle"),
        .repeat: DisplayRepresentation(title: "Repeat"),
    ]
}

/// Where in the queue a play request's tracks should land.
@AppEnum(schema: .audio.queueInsertionLocation)
enum QueueInsertionLocation: String {
    case next
    case tail

    static let caseDisplayRepresentations: [QueueInsertionLocation: DisplayRepresentation] = [
        .next: DisplayRepresentation(title: "Next"),
        .tail: DisplayRepresentation(title: "Last"),
    ]
}
#endif
