import SwiftUI

/// Standard macOS Settings scene content. `Settings` automatically installs
/// the app-menu item and ⌘, shortcut; this view only supplies the panes.
struct SettingsView: View {
    @EnvironmentObject private var model: AppModel
    @AppStorage("notifyOnRunFinish") private var notifyOnRunFinish = true
    @AppStorage("indexProjectsInSpotlight") private var indexProjectsInSpotlight = true
    @AppStorage("handoffEnabled") private var handoffEnabled = true

    var body: some View {
        TabView {
            executionSettings
                .tabItem { IconLabel("Execution", icon: "play-rectangle") }
            integrationSettings
                .tabItem { IconLabel("Integrations", icon: "layers") }
            privacySettings
                .tabItem { IconLabel("Privacy", icon: "shield") }
        }
        .frame(width: 540, height: 460)
    }

    private var executionSettings: some View {
        Form {
            Section {
                TextField("Entry file", text: $model.entryPoint)
                    .textFieldStyle(.roundedBorder)
                    .help("The file Stateglass runs.")
                    .accessibilityLabel("Entry file")
                TextField("Arguments", text: $model.runArguments)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel("Arguments")
                TextField("Standard input", text: $model.runStdin)
                    .textFieldStyle(.roundedBorder)
                    .help("Text passed to the program as stdin")
                    .accessibilityLabel("Standard input")
                Stepper(value: $model.timeoutSeconds, in: 1...600) {
                    LabeledContent("Timeout", value: "\(model.timeoutSeconds) s")
                }
                Toggle("Record values", isOn: $model.tracingEnabled)
                    .help("Turn this off only if you want output without recorded values.")
            } header: {
                Text("Run configuration")
            } footer: {
                Text("The entry file is what Stateglass runs. Recording values lets you click a result and see where it came from. Turn recording off only if you want output without recorded values.")
            }

            Section {
                TextField("Interpreter path (optional)", text: $model.pythonPath)
                    .textFieldStyle(.roundedBorder)
                    .help("Leave empty to use python on your PATH, or a project .venv when one is present.")
                    .accessibilityLabel("Python interpreter path")
                HStack {
                    Button("Save Project Settings") {
                        Task {
                            do {
                                try await model.saveSettings()
                                model.notice = "Run settings saved"
                            } catch {
                                model.notice = error.localizedDescription
                            }
                        }
                    }
                    .disabled(model.project == nil)
                    Button("Save Global Path") {
                        Task { await model.saveGlobalPythonPath() }
                    }
                }
            } header: {
                Text("Python")
            } footer: {
                Text("Leave the path empty to use python on your PATH. A project .venv is detected automatically.")
            }
        }
        .formStyle(.grouped)
    }

    private var integrationSettings: some View {
        Form {
            Section {
                Toggle("Notify when a run finishes", isOn: $notifyOnRunFinish)
                Toggle("Include projects in Spotlight", isOn: $indexProjectsInSpotlight)
                Toggle("Continue projects with Handoff", isOn: $handoffEnabled)
            } footer: {
                Text("These features use system frameworks and can be disabled at any time here or in System Settings.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("Automation") {
                LabeledContent("Shortcuts", value: "Run Project, Open Project")
                LabeledContent("AppleScript", value: "Open project via Services")
                Text("The app also exposes a Dock menu, a Services menu item, and a menu bar extra.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private var privacySettings: some View {
        Form {
            Section("Data") {
                LabeledContent("Trace data", value: "Stored locally")
                LabeledContent("Network", value: "None required")
                LabeledContent("Telemetry", value: "Off")
            }
            Section {
                Text("Stateglass executes project code with your user privileges. Treat it like a terminal, not a sandbox. iCloud sync is opt-in and never includes console output or captured values by default.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}
