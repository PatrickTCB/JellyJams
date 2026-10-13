import SwiftUI

/// The downloads status bar, under the section's segmented picker while a
/// download runs.
///
/// Three lines: a spinner beside "Downloading", a bar that fills by songs
/// resolved, and throughput. The spinner is the activity signal — the bar
/// only steps when a song finishes, so mid-file it sits still and something
/// needs to say work is ongoing. The speed is re-read once a second by the
/// enclosing ``TimelineView``, which is what lets it fall as samples age out
/// of the tracker's window instead of freezing at the last landed byte.
struct DownloadStatusBar: View {
    @EnvironmentObject private var downloads: DownloadStore

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { timeline in
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text("Downloading")
                        .font(.callout)
                    ProgressView()
                        .controlSize(.small)
                }
                ProgressView(value: progress?.fraction ?? 0)
                if let speed = downloads.downloadBytesPerSecond(asOf: timeline.date) {
                    Text(Format.speed(bytesPerSecond: speed))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal)
            .padding(.bottom, 8)
        }
    }

    private var progress: DownloadStore.DownloadProgress? {
        downloads.activeDownloadProgress
    }
}
