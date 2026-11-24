import AppKit
import SwiftUI

/// Semantic design tokens backed by AppKit system colors.
///
/// Using dynamic `NSColor` values instead of fixed RGB literals means the app
/// automatically follows the system accent color, appearance changes, Increase
/// Contrast, and Reduce Transparency. No `.preferredColorScheme` override is
/// required (or wanted).
enum GlassTheme {
    static let canvas = Color(nsColor: .windowBackgroundColor)
    static let panel = Color(nsColor: .controlBackgroundColor)
    static let raised = Color(nsColor: .unemphasizedSelectedContentBackgroundColor)
    static let selection = Color(nsColor: .selectedContentBackgroundColor)
    static let border = Color(nsColor: .separatorColor)
    static let accent = Color.accentColor
    static let text = Color(nsColor: .labelColor)
    static let muted = Color(nsColor: .secondaryLabelColor)
    static let tertiary = Color(nsColor: .tertiaryLabelColor)
    static let green = Color(nsColor: .systemGreen)
    static let red = Color(nsColor: .systemRed)
    static let warning = Color(nsColor: .systemOrange)
    /// Code surface. Matches `NSTextView` so the gutter, tabs, and editor read as one plane.
    static let editor = Color(nsColor: .textBackgroundColor)
    /// Window chrome behind tabs and the status bar.
    static let chrome = Color(nsColor: .windowBackgroundColor)
}

enum FileIcons {
    static func name(for path: String, isDir: Bool) -> String {
        if isDir { return "folder" }
        switch URL(fileURLWithPath: path).pathExtension.lowercased() {
        case "py", "swift", "js", "jsx", "ts", "tsx", "rs", "json":
            return "code"
        default:
            return "file"
        }
    }
}

enum GlassMetrics {
    static let sidebarMin: CGFloat = 190
    static let sidebarIdeal: CGFloat = 245
    static let sidebarMax: CGFloat = 340
    static let inspectorMin: CGFloat = 235
    static let inspectorIdeal: CGFloat = 290
    static let inspectorMax: CGFloat = 390
    static let consoleMin: CGFloat = 100
    static let consoleIdeal: CGFloat = 170
}

/// Small helpers shared by several views.
enum FileActions {
    static func reveal(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    static func copyPath(_ url: URL) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url.path, forType: .string)
    }
}
