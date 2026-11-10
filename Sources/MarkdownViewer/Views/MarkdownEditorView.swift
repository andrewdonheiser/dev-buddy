import SwiftUI

/// A plain-text editor for the Markdown source of the open document, shown in
/// place of the rendered page while the document is being edited.
struct MarkdownEditorView: View {
    @Binding var text: String

    var body: some View {
        TextEditor(text: $text)
            .font(.system(size: 13, design: .monospaced))
            .scrollContentBackground(.hidden)
            .background(Color(nsColor: .textBackgroundColor))
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
    }
}
