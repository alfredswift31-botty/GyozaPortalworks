import SwiftUI

/// Re-draws its content on every simulation refresh.
///
/// Rows in a lazy container (LazyVGrid, LazyVStack) are built by the
/// container, not by the view that reads `session.frame`, so values read
/// while building a row go stale while the CPU runs. Wrap such rows in this,
/// or read `session.frame` in the row's own body.
struct LiveRefresh<Content: View>: View {
    let session: SimulationSession?
    @ViewBuilder let content: () -> Content

    var body: some View {
        let _ = session?.frame
        content()
    }
}
