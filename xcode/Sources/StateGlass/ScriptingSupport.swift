import Foundation

/// AppleScript / JXA bridge. The command classes are referenced by name from
/// `Support/Stateglass.sdef`; `OSAScriptingDefinition` in `Info.plist` points at
/// that dictionary. Example:
///
///     osascript -e 'tell application "Stateglass" to open project "/Users/me/src/demo"'
///     osascript -e 'tell application "Stateglass" to run project'
///
/// This is intentionally thin: the same `AppModel` entry points used by the UI,
/// App Intents, Services, and Handoff are reused, so consent and backend
/// lifecycle rules never diverge.

@objc(OpenProjectScriptCommand)
final class OpenProjectScriptCommand: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        guard let path = directParameter as? String, !path.isEmpty else {
            scriptErrorNumber = NSArgumentsWrongScriptError
            scriptErrorString = "Expected a project folder path."
            return nil
        }
        Task { @MainActor in
            await AppModel.shared.openProjectFromIntent(path: path)
        }
        return nil
    }
}

@objc(RunProjectScriptCommand)
final class RunProjectScriptCommand: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        Task { @MainActor in
            await AppModel.shared.run()
        }
        return nil
    }
}
