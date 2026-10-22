#if os(macOS)
import SwiftUI

/// The macOS playback volume control: a standard slider flanked by speaker
/// glyphs, bound to ``PlayerController/volume``.
struct VolumeSlider: View {
    @EnvironmentObject private var player: PlayerController

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "speaker.fill")
                .accessibilityHidden(true)
            Slider(value: $player.volume, in: 0...1) {
                Text("Volume")
            }
            .labelsHidden()
            .controlSize(.small)
            Image(systemName: "speaker.wave.3.fill")
                .accessibilityHidden(true)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }
}
#endif
