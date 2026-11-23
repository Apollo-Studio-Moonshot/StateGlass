import AppIntents
import Foundation

/// App Intents power Shortcuts, Siri, Spotlight actions, and Focus filters.
/// These intents call the shared `AppModel`, so they respect the same consent
/// gate and sandbox-adjacent process model as the UI.

struct RunProjectIntent: AppIntent {
    static var title: LocalizedStringResource { "Run Project" }
    static var description: IntentDescription? {
        IntentDescription("Run the project currently open in Stateglass.")
    }
    static var openAppWhenRun: Bool { true }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let model = AppModel.shared
        guard let project = model.project else {
            return .result(dialog: "Open a project in Stateglass first.")
        }
        await model.run()
        return .result(dialog: "Running \(project.name).")
    }
}

struct OpenProjectIntent: AppIntent {
    static var title: LocalizedStringResource { "Open Project in Stateglass" }
    static var description: IntentDescription? {
        IntentDescription("Open a local project folder in Stateglass.")
    }
    static var openAppWhenRun: Bool { true }

    @Parameter(title: "Project Folder", description: "Absolute path to the project folder.")
    var projectPath: String

    init() {}

    init(projectPath: String) {
        self.projectPath = projectPath
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let url = URL(fileURLWithPath: (projectPath as NSString).expandingTildeInPath)
        await AppModel.shared.openProjectFromURL(url)
        return .result(dialog: "Opened \(url.lastPathComponent).")
    }
}

struct StateGlassShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: RunProjectIntent(),
            phrases: ["Run project in \(.applicationName)"],
            shortTitle: "Run Project",
            systemImageName: "play.fill"
        )
        AppShortcut(
            intent: OpenProjectIntent(),
            phrases: ["Open project in \(.applicationName)"],
            shortTitle: "Open Project",
            systemImageName: "folder"
        )
    }
}
