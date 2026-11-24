import AppKit
import SwiftUI

@main
struct StateGlassApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = AppModel.shared

    var body: some Scene {
        WindowGroup(id: "main") {
            ContentView()
                .environmentObject(model)
                .frame(minWidth: 960, minHeight: 620)
        }
        .defaultSize(width: 1120, height: 720)
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Open Project…") { model.openProjectPanel() }
                    .keyboardShortcut("o", modifiers: .command)
                Button("Load Sample Project") { Task { await model.loadSample() } }
                Divider()
                Button("Save File") { Task { await model.saveFile() } }
                    .keyboardShortcut("s", modifiers: .command)
                    .disabled(model.selectedFile == nil)
                Button("Close Editor") {
                    if let path = model.selectedFile { model.requestClose(path) }
                }
                .keyboardShortcut("w", modifiers: .command)
                .disabled(model.selectedFile == nil)
            }

            CommandGroup(replacing: .printItem) {}

            CommandMenu("Go") {
                Button("Go to File…") { model.presentPalette(.files) }
                    .keyboardShortcut("p", modifiers: .command)
                    .disabled(model.project == nil)
                Button("Command Palette…") { model.presentPalette(.commands) }
                    .keyboardShortcut("p", modifiers: [.command, .shift])
            }

            CommandMenu("Run") {
                Button("Run Project") { Task { await model.run() } }
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(model.project == nil || model.isRunning)
                Button("Cancel Run") { Task { await model.cancelRun() } }
                    .keyboardShortcut(".", modifiers: .command)
                    .disabled(!model.isRunning)
                Divider()
                Button("New Experiment…") { model.showNewExperiment = true }
                    .keyboardShortcut("e", modifiers: [.command, .shift])
            }

            CommandGroup(after: .sidebar) {
                Divider()
                Button("Canvas") { model.centerTab = .canvas }
                    .keyboardShortcut("0", modifiers: .command)
                Button("Editor") { model.centerTab = .editor }
                    .keyboardShortcut("1", modifiers: .command)
                Button("Data Flow") { model.centerTab = .flow }
                    .keyboardShortcut("2", modifiers: .command)
                Button("Compare") { model.centerTab = .compare }
                    .keyboardShortcut("3", modifiers: .command)
                Button("Experiments") { model.centerTab = .experiments }
                    .keyboardShortcut("4", modifiers: .command)
                Divider()
                Button(model.showInspector ? "Hide Inspector" : "Show Inspector") {
                    model.showInspector.toggle()
                }
                .keyboardShortcut("i", modifiers: [.command, .option])
                .disabled(model.project == nil)
            }

            SidebarCommands()
            ToolbarCommands()
            TextEditingCommands()
        }

        Settings {
            SettingsView()
                .environmentObject(model)
        }

        MenuBarExtra {
            MenuBarContent(model: model)
        } label: {
            AppIcon("logo", size: 18, label: "Stateglass")
        }
        .menuBarExtraStyle(.menu)
    }
}

private struct MenuBarContent: View {
    @ObservedObject var model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Show Stateglass") {
            openWindow(id: "main")
            NSApp.activate()
        }
        Divider()
        Button("Open Project…") { model.openProjectPanel() }
        Button("Run Project") { Task { await model.run() } }
            .disabled(model.project == nil || model.isRunning)
        Button("Cancel Run") { Task { await model.cancelRun() } }
            .disabled(!model.isRunning)
        Divider()
        SettingsLink { Text("Settings…") }
        Divider()
        Button("Quit Stateglass") { NSApp.terminate(nil) }
            .keyboardShortcut("q", modifiers: .command)
    }
}
