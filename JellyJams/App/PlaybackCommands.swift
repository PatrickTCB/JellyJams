import SwiftUI

/// Native menu-bar commands for playback, wired to the shared
/// ``PlayerController``. Added to the app's `Controls` menu on macOS.
struct PlaybackCommands: Commands {
    @ObservedObject var player: PlayerController

    var body: some Commands {
        CommandMenu("Controls") {
            Button(player.isPlaying ? "Pause" : "Play") { player.togglePlayPause() }
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(!player.hasQueue)

            Button("Next") { player.next() }
                .keyboardShortcut(.rightArrow, modifiers: .command)
                .disabled(!player.canGoNext)

            Button("Previous") { player.previous() }
                .keyboardShortcut(.leftArrow, modifiers: .command)
                .disabled(!player.canGoPrevious)

            Divider()

            Button(player.isShuffled ? "Shuffle: On" : "Shuffle: Off") { player.toggleShuffle() }
                .keyboardShortcut("s", modifiers: [.command, .shift])
                .disabled(!player.hasQueue)

            Button("Cycle Repeat Mode") { player.cycleRepeatMode() }
                .keyboardShortcut("r", modifiers: [.command, .shift])
                .disabled(!player.hasQueue)
        }
    }
}
