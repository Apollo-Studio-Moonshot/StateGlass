import AppKit
import SwiftUI

/// Every icon in the app is drawn from a standalone SVG file in `Icons/`.
/// Files are loaded once, cached, and rendered as templates so they pick up the
/// surrounding foreground style (accent color, warning color, Increase Contrast).
@MainActor
enum AppIcons {
    private static let cache = NSCache<NSString, NSImage>()

    static func image(named name: String) -> NSImage? {
        if let cached = cache.object(forKey: name as NSString) {
            return cached
        }
        guard let url = Bundle.module.url(forResource: name, withExtension: "svg", subdirectory: "Icons"),
              let image = NSImage(contentsOf: url) else {
            return nil
        }
        // Keep a logical size with enough headroom that large presentations
        // (welcome screen, empty states) stay crisp on Retina displays.
        image.size = NSSize(width: 128, height: 128)
        image.isTemplate = true
        cache.setObject(image, forKey: name as NSString)
        return image
    }
}

/// Displays an SVG icon at an explicit point size.
struct AppIcon: View {
    let name: String
    var size: CGFloat = 16
    var label: String?

    init(_ name: String, size: CGFloat = 16, label: String? = nil) {
        self.name = name
        self.size = size
        self.label = label
    }

    var body: some View {
        Group {
            if let image = AppIcons.image(named: name) {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .frame(width: size, height: size)
            } else {
                Color.clear
                    .frame(width: size, height: size)
            }
        }
        .accessibilityElement()
        .accessibilityHidden(label == nil)
        .accessibilityLabel(Text(label ?? ""))
    }
}

/// A `Label` with a text title and an SVG icon, matching the ergonomics of
/// `Label(_:systemImage:)`.
struct IconLabel: View {
    let title: String
    let icon: String
    var size: CGFloat = 15

    init(_ title: String, icon: String, size: CGFloat = 15) {
        self.title = title
        self.icon = icon
        self.size = size
    }

    var body: some View {
        Label {
            Text(title)
        } icon: {
            AppIcon(icon, size: size)
        }
    }
}
