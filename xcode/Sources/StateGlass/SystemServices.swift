import AppKit
import CoreSpotlight
import Foundation
import OSLog
import QuickLookUI
import Security
import UniformTypeIdentifiers
import UserNotifications

// MARK: - Notifications

enum NotificationService {
    private static let logger = Logger(subsystem: "dev.stateglass.app", category: "notifications")

    /// UserNotifications throws an ObjC exception, not a Swift error, when the
    /// process is a bare `swift run` binary with no app bundle.
    private static var isBundledApp: Bool {
        Bundle.main.bundleURL.pathExtension == "app"
    }

    /// `UNUserNotificationCenter` — requested once at launch. The user can
    /// change this at any time in System Settings, so failures are non-fatal.
    static func requestAuthorization() async {
        guard isBundledApp else { return }
        do {
            _ = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
        } catch {
            logger.info("Notification authorization unavailable: \(error.localizedDescription, privacy: .public)")
        }
    }

    static func runFinished(projectName: String, status: String, durationMs: Int64?) {
        guard isBundledApp else { return }
        guard UserDefaults.standard.object(forKey: "notifyOnRunFinish") as? Bool ?? true else { return }
        let content = UNMutableNotificationContent()
        content.title = status == "ok" ? "Run finished" : "Run \(status)"
        var body = projectName
        if let durationMs {
            body += " · \(String(format: "%.2fs", Double(durationMs) / 1000))"
        }
        content.body = body
        content.sound = .default
        // `interruptionLevel` is intentionally not set: runs finishing is
        // useful but not time-sensitive, so the default level is correct.
        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request) { error in
            if let error {
                logger.info("Could not post completion notification: \(error.localizedDescription, privacy: .public)")
            }
        }
    }
}

// MARK: - Spotlight

enum SpotlightIndexer {
    private static let domainIdentifier = "dev.stateglass.projects"
    private static let logger = Logger(subsystem: "dev.stateglass.app", category: "spotlight")

    /// Indexes recently opened projects with Core Spotlight so they appear in
    /// Spotlight and can be resumed through `NSUserActivity` continuation.
    static func index(project: Project) {
        guard UserDefaults.standard.object(forKey: "indexProjectsInSpotlight") as? Bool ?? true else { return }
        let attributes = CSSearchableItemAttributeSet(contentType: .sourceCode)
        attributes.title = project.name
        attributes.contentDescription = "Stateglass project · \(project.rootPath)"
        attributes.keywords = ["Stateglass", "project", project.language]
        attributes.relatedUniqueIdentifier = "project-\(project.id)"
        let item = CSSearchableItem(
            uniqueIdentifier: "project-\(project.id)",
            domainIdentifier: domainIdentifier,
            attributeSet: attributes
        )
        CSSearchableIndex.default().indexSearchableItems([item]) { error in
            if let error {
                logger.info("Spotlight indexing failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    static func removeAll() {
        CSSearchableIndex.default().deleteSearchableItems(withDomainIdentifiers: [domainIdentifier]) { error in
            if let error {
                logger.info("Spotlight cleanup failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }
}

// MARK: - Handoff / Continuity

@MainActor
enum HandoffService {
    static let activityType = "dev.stateglass.project"
    private static var current: NSUserActivity?

    /// Advertise the open project to other devices through Handoff.
    static func begin(project: Project) {
        guard UserDefaults.standard.object(forKey: "handoffEnabled") as? Bool ?? true else {
            end()
            return
        }
        current?.invalidate()
        let activity = NSUserActivity(activityType: activityType)
        activity.title = project.name
        activity.isEligibleForHandoff = true
        activity.isEligibleForSearch = true
        activity.userInfo = ["projectPath": project.rootPath]
        activity.becomeCurrent()
        current = activity
    }

    static func end() {
        current?.invalidate()
        current = nil
    }
}

// MARK: - Keychain

enum KeychainError: LocalizedError {
    case status(OSStatus)

    var errorDescription: String? {
        switch self {
        case .status(let status):
            SecCopyErrorMessageString(status, nil) as String? ?? "Keychain error \(status)"
        }
    }
}

/// Thin wrapper over `SecItem` for secrets that must not live in
/// `UserDefaults` (for example, a user-supplied interpreter token or a
/// notarization profile name). Account names are stable strings.
enum KeychainStore {
    private static let service = "dev.stateglass.app"

    private static func baseQuery(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    static func save(_ secret: Data, account: String) throws {
        let query = baseQuery(account: account)
        SecItemDelete(query as CFDictionary)
        var attributes = query
        attributes[kSecValueData as String] = secret
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeychainError.status(status) }
    }

    static func read(account: String) throws -> Data? {
        var query = baseQuery(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            return result as? Data
        case errSecItemNotFound:
            return nil
        default:
            throw KeychainError.status(status)
        }
    }

    static func delete(account: String) {
        SecItemDelete(baseQuery(account: account) as CFDictionary)
    }
}

// MARK: - Quick Look

@MainActor
final class QuickLookController: NSObject, QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    static let shared = QuickLookController()
    private var url: URL?

    func preview(_ url: URL) {
        self.url = url
        guard let panel = QLPreviewPanel.shared() else { return }
        panel.dataSource = self
        panel.delegate = self
        panel.reloadData()
        panel.makeKeyAndOrderFront(nil)
    }

    nonisolated func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        1
    }

    nonisolated func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> any QLPreviewItem {
        // `url` is only mutated on the main actor, and Quick Look calls these
        // methods from the main thread.
        MainActor.assumeIsolated { (self.url ?? URL(fileURLWithPath: "/")) as NSURL }
    }
}

// MARK: - Sharing

@MainActor
enum SharingService {
    /// `NSSharingServicePicker` is the AppKit entry point used by the
    /// standard Share sheet. SwiftUI's `ShareLink` is preferred in new views;
    /// this helper exists for AppKit call sites such as the Dock menu.
    static func share(_ items: [Any], from view: NSView) {
        NSSharingServicePicker(items: items)
            .show(relativeTo: view.bounds, of: view, preferredEdge: .minY)
    }
}

// MARK: - Dock menu, Services, and app lifecycle

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.servicesProvider = ServiceProvider()
        NSApp.registerServicesMenuSendTypes(
            [.fileURL, NSPasteboard.PasteboardType("NSFilenamesPboardType")],
            returnTypes: []
        )
        Task { await NotificationService.requestAuthorization() }
    }

    /// Dock menu — a genuine macOS affordance that web shells cannot provide.
    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        let menu = NSMenu()
        let open = NSMenuItem(title: "Open Project…", action: #selector(openProject), keyEquivalent: "")
        open.target = self
        menu.addItem(open)
        let run = NSMenuItem(title: "Run Project", action: #selector(runProject), keyEquivalent: "")
        run.target = self
        menu.addItem(run)
        menu.addItem(.separator())
        let share = NSMenuItem(title: "Share Project Folder…", action: #selector(shareProject), keyEquivalent: "")
        share.target = self
        menu.addItem(share)
        return menu
    }

    /// Finder "Open With" / folder drops.
    func application(_ application: NSApplication, open urls: [URL]) {
        guard let folder = urls.first(where: { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }) else {
            return
        }
        Task { await AppModel.shared.openProjectFromURL(folder) }
    }

    /// Resume a project from Handoff or a Spotlight result.
    func application(
        _ application: NSApplication,
        continue userActivity: NSUserActivity,
        restorationHandler: @escaping ([any NSUserActivityRestoring]) -> Void
    ) -> Bool {
        guard userActivity.activityType == HandoffService.activityType,
              let path = userActivity.userInfo?["projectPath"] as? String
        else {
            return false
        }
        Task { await AppModel.shared.openProjectFromURL(URL(fileURLWithPath: path)) }
        return true
    }

    @objc private func openProject() {
        AppModel.shared.openProjectPanel()
    }

    @objc private func runProject() {
        Task { await AppModel.shared.run() }
    }

    @objc private func shareProject() {
        guard let path = AppModel.shared.project?.rootPath else { return }
        let picker = NSSharingServicePicker(items: [URL(fileURLWithPath: path)])
        if let window = NSApp.keyWindow, let view = window.contentView {
            picker.show(relativeTo: view.bounds, of: view, preferredEdge: .minY)
        }
    }
}

@MainActor
final class ServiceProvider: NSObject {
    /// Implements the `NSServices` entry declared in `Info.plist`.
    @objc func openProject(
        _ pboard: NSPasteboard,
        userData: String,
        error: AutoreleasingUnsafeMutablePointer<NSString>
    ) {
        guard let urls = pboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) as? [URL], let folder = urls.first else {
            error.pointee = "Select a project folder in Finder." as NSString
            return
        }
        Task { await AppModel.shared.openProjectFromURL(folder) }
    }
}
