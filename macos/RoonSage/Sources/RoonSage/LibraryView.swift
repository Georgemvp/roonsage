import SwiftUI

struct LibraryView: View {
    var body: some View {
        ContentUnavailableView(
            "Library",
            systemImage: "music.note.list",
            description: Text("Library sync and browsing — coming in Phase 1B.")
        )
        .navigationTitle("Library")
    }
}
