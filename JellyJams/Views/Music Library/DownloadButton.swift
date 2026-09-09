import SwiftUI

/// Icon-only download toggle with loading indicator
struct DownloadButton: View {
    let item: BaseItemDto
    var size: Font = .body

    @EnvironmentObject private var downloads: DownloadStore

    private var isDownloaded: Bool { downloads.isDownloaded(item) }

    var body: some View {
        if downloads.isBusy(item) {
            ProgressView()
                .controlSize(.small)
                .frame(width: 20, height: 20) // roughly match the icon size
        } else if isDownloaded {
            Button {downloads.remove(item)} label: {
                Image(systemName: "arrow.down.circle.fill")
                    .font(size)
            }
            .help("Remove download")
            .accessibilityLabel("Remove download")
            .buttonStyle(.borderless)
            .tint(.accentColor)
        } else {
            Button {downloads.download(item)} label: {
                Image(systemName: "arrow.down.circle.dotted")
                    .font(size)
            }
            .help("Download \(item.name ?? "item")")
            .accessibilityLabel("Download \(item.name ?? "item")")
            .buttonStyle(.borderless)
            .tint(Color.gray)
        }
    }
}
