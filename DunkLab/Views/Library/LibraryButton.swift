import SwiftUI

extension View {
    /// The video library's button, top right on every tab. Opens inside the
    /// tab's own stack, so Back returns to where you were.
    func libraryButton() -> some View {
        toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                NavigationLink { ClipLibraryView() } label: {
                    Label("Library", systemImage: "film.stack")
                }
            }
        }
    }
}
