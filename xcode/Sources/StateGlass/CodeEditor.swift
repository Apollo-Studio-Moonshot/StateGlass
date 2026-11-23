import SwiftUI

/// A native `NSTextView` (via `NSViewRepresentable`) instead of SwiftUI's
/// `TextEditor`. This buys undo/redo, the system Find bar, native selection and
/// insertion behavior, accessibility text semantics, and future syntax
/// highlighting through `NSTextStorage` attributes — all without a web editor.
struct CodeEditor: NSViewRepresentable {
    @Binding var text: String

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false

        guard let textView = scrollView.documentView as? NSTextView else {
            return scrollView
        }
        textView.delegate = context.coordinator
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.usesFindPanel = true
        textView.isIncrementalSearchingEnabled = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        textView.textColor = .labelColor
        textView.insertionPointColor = .labelColor
        textView.backgroundColor = .textBackgroundColor
        textView.textContainerInset = NSSize(width: 10, height: 10)
        textView.isEditable = true
        textView.isSelectable = true
        textView.string = text
        textView.setAccessibilityLabel("Source code editor")
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let textView = scrollView.documentView as? NSTextView else { return }
        if textView.string != text {
            let selection = textView.selectedRanges
            textView.string = text
            textView.selectedRanges = selection.filter {
                ($0.rangeValue.location + $0.rangeValue.length) <= text.utf16.count
            }
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: CodeEditor

        init(_ parent: CodeEditor) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            parent.text = textView.string
        }
    }
}
