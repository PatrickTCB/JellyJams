import SwiftUI

/// Quick links to the first few AI Radio stations, for starting one without
/// going through the AI Radio tab. The section is only rendered while the
/// feature is active and there are stations to show.
struct AIRadioQuickLinksSection: View {
    let stations: [BaseItemDto]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("🤖 Radio")
                .font(.title2.bold())
                .padding(.horizontal)
            HomeItemRow(items: stations) { StationTile(station: $0) }
        }
    }
}
