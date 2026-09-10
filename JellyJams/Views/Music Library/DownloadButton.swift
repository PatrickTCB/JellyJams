import SwiftUI

/// Icon-only download toggle with loading indicator
struct DownloadButton: View {
    let item: BaseItemDto
    #if os(macOS)
    var size: Font = .title2
    #else
    var size: Font = .body
    #endif

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
            #if os(iOS)
            .buttonStyle(.borderless)
            #else
            .buttonStyle(.bordered)
            #endif
            .tint(.accentColor)
        } else {
            Button {downloads.download(item)} label: {
                Image(systemName: "arrow.down.circle.dotted")
                    .font(size)
            }
            .help("Download \(item.name ?? "item")")
            .accessibilityLabel("Download \(item.name ?? "item")")
            #if os(iOS)
            .buttonStyle(.borderless)
            #else
            .buttonStyle(.bordered)
            #endif
            .tint(Color.gray)
        }
    }
}
