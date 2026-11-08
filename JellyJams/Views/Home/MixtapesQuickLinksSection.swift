import SwiftUI

/// Quick links to the first few backend-built mixtapes, for starting one
/// without going through the Mixtapes tab. The section is only rendered while
/// the app is registered with a backend and there are mixtapes to show.
struct MixtapesQuickLinksSection: View {
    let mixtapes: [BaseItemDto]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Mixtapes")
                .font(.title2.bold())
                .padding(.horizontal)
            HomeItemRow(items: mixtapes) { MixtapeTile(mixtape: $0) } trailing: {
                BrowseMoreTile(section: .mixtapes)
            }
        }
    }
}
