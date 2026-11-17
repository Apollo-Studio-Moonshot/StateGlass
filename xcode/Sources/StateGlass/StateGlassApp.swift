import SwiftUI

@main
struct StateGlassApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(model)
                .frame(minWidth: 1050, minHeight: 680)
                .preferredColorScheme(.dark)
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Open Project…") { model.openProjectPanel() }
                    .keyboardShortcut("o", modifiers: .command)
                Button("Save File") { Task { await model.saveFile() } }
                    .keyboardShortcut("s", modifiers: .command)
                Divider()
                Button("Run Project") { Task { await model.run() } }
                    .keyboardShortcut(.return, modifiers: .command)
                Button("Cancel Run") { Task { await model.cancelRun() } }
                    .keyboardShortcut(".", modifiers: .command)
                Divider()
                Button("New Experiment…") { model.showNewExperiment = true }
                    .keyboardShortcut("e", modifiers: [.command, .shift])
                Button("Editor") { model.centerTab = .editor }
                    .keyboardShortcut("1", modifiers: .command)
                Button("Data Flow") { model.centerTab = .flow }
                    .keyboardShortcut("2", modifiers: .command)
                Button("Compare") { model.centerTab = .compare }
                    .keyboardShortcut("3", modifiers: .command)
                Button("Experiments") { model.centerTab = .experiments }
                    .keyboardShortcut("4", modifiers: .command)
            }
        }
    }
}
