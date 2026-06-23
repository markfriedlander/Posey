import SwiftUI

// ========== BLOCK 01: SURFACE COVER MODIFIER - START ==========

/// Presents the rebuilt one-surface reader (`ReaderSurfaceView`) as a full-screen
/// cover when the DEBUG antenna verb `OPEN_DOCUMENT_SURFACE:<docID>` fires. Exists in
/// all configs so the LibraryView body stays unconditional (type-checker happy), but
/// is a NO-OP in RELEASE — the verb that triggers it is DEBUG-only. Isolated from the
/// shipping reader so render/memory testing can't disturb it (Stage B).
struct SurfaceCoverModifier: ViewModifier {
    let databaseManager: DatabaseManager
    @State private var surfaceDocument: Document?

    func body(content: Content) -> some View {
        #if DEBUG
        content
            .onReceive(NotificationCenter.default.publisher(for: .remoteOpenDocumentSurface)) { note in
                guard let id = note.userInfo?["documentID"] as? UUID,
                      let doc = (try? databaseManager.documents())?.first(where: { $0.id == id })
                else { return }
                // Dismiss-then-present so reopening the SAME doc forces a fresh build
                // from the current DB (needed to pick up a text mutation in the R8 test).
                surfaceDocument = nil
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { surfaceDocument = doc }
            }
            .fullScreenCover(item: $surfaceDocument) { doc in
                ReaderSurfaceView(document: doc, databaseManager: databaseManager,
                                  onClose: { surfaceDocument = nil })
            }
        #else
        content
        #endif
    }
}

// ========== BLOCK 01: SURFACE COVER MODIFIER - END ==========
