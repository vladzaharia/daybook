import DaybookUI
import SwiftUI

/// Summary Templates (Direction A §5.16): DaybookUI's `TemplatesScreen`, the iPhone's screen, as a window. The
/// built-in templates in a fixed order, the person's own, and an editor that saves as they type
/// (docs/templates.md). `--templates-demo` fills a scratch library's templates (DaybookUI's `TemplatesDemo`).
struct TemplatesView: View {
    let state: AppState

    var body: some View {
        TemplatesScreen(library: state.library)
    }
}
