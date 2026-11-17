import SwiftUI
import AppKit

private enum Palette {
    static let canvas = Color(red: 0.055, green: 0.067, blue: 0.09)
    static let panel = Color(red: 0.075, green: 0.09, blue: 0.12)
    static let raised = Color(red: 0.105, green: 0.125, blue: 0.16)
    static let border = Color.white.opacity(0.08)
    static let accent = Color(red: 0.39, green: 0.75, blue: 0.95)
    static let muted = Color(red: 0.55, green: 0.61, blue: 0.69)
    static let green = Color(red: 0.39, green: 0.82, blue: 0.61)
    static let red = Color(red: 0.95, green: 0.42, blue: 0.4)
}

struct ContentView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        Group {
            if model.booting {
                ProgressView("Preparing Stateglass…")
                    .controlSize(.large)
            } else if let bootError = model.bootError {
                VStack(spacing: 14) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 36))
                        .foregroundStyle(Palette.red)
                    Text("Stateglass could not start").font(.title2.bold())
                    Text(bootError)
                        .foregroundStyle(Palette.muted)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 540)
                    Button("Retry") { Task { await model.start() } }
                        .buttonStyle(.borderedProminent)
                }
                .padding(40)
            } else if model.project == nil {
                WelcomeView()
            } else {
                WorkspaceView()
            }
        }
        .background(Palette.canvas)
        .task { await model.start() }
        .alert("Run project code?", isPresented: $model.showConsent) {
            Button("Cancel", role: .cancel) {}
            Button("Allow and Run") { Task { await model.grantConsentAndRun() } }
        } message: {
            Text("Stateglass runs code with your user privileges. It is not a security sandbox.")
        }
        .alert("Stateglass", isPresented: Binding(
            get: { model.notice != nil },
            set: { if !$0 { model.notice = nil } }
        )) {
            Button("OK") { model.notice = nil }
        } message: {
            Text(model.notice ?? "")
        }
        .sheet(isPresented: $model.showNewExperiment) {
            NewExperimentSheet()
                .environmentObject(model)
                .frame(width: 420)
        }
    }
}

private struct WelcomeView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "waveform.path.ecg.rectangle")
                .font(.system(size: 48, weight: .light))
                .foregroundStyle(Palette.accent)
            Text("Stateglass")
                .font(.system(size: 30, weight: .semibold, design: .rounded))
            Text("Trace how values are produced. Experiment safely against a recorded baseline.")
                .foregroundStyle(Palette.muted)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 450)
            HStack(spacing: 12) {
                Button("Open Project…") { model.openProjectPanel() }
                    .buttonStyle(.borderedProminent)
                Button("Load Sample Project") { Task { await model.loadSample() } }
                    .buttonStyle(.bordered)
            }
            if !model.projects.isEmpty {
                VStack(alignment: .leading, spacing: 7) {
                    Text("RECENT PROJECTS")
                        .font(.system(size: 10, weight: .bold)).tracking(1)
                        .foregroundStyle(Palette.muted)
                    ForEach(model.projects) { project in
                        Button {
                            Task { await model.openRecentProject(project) }
                        } label: {
                            HStack {
                                Image(systemName: "folder")
                                VStack(alignment: .leading) {
                                    Text(project.name)
                                    Text(project.rootPath).font(.system(size: 9, design: .monospaced)).foregroundStyle(Palette.muted)
                                }
                                Spacer()
                                Image(systemName: "chevron.right").foregroundStyle(Palette.muted)
                            }
                            .font(.system(size: 11))
                            .padding(9)
                            .background(Palette.panel, in: RoundedRectangle(cornerRadius: 6))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .frame(maxWidth: 450, alignment: .leading)
                .padding(.top, 8)
            }
        }
        .padding(40)
    }
}

private struct WorkspaceView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            WorkspaceToolbar()
            HSplitView {
                ProjectSidebar()
                    .frame(minWidth: 190, idealWidth: 245, maxWidth: 340)
                VSplitView {
                    CenterWorkspace()
                        .frame(minWidth: 420, minHeight: 260)
                    ConsolePanel()
                        .frame(minHeight: 100, idealHeight: 170)
                }
                .frame(minWidth: 420)
                InspectorSidebar()
                    .frame(minWidth: 235, idealWidth: 290, maxWidth: 390)
            }
            .padding(.horizontal, 8)
            StatusBar()
        }
        .background(Palette.canvas)
    }
}

private struct WorkspaceToolbar: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        HStack(spacing: 12) {
            Button(action: model.openProjectPanel) {
                Label("Open", systemImage: "folder")
            }
            .help("Open a project folder (⌘O)")
            Button {
                Task { await model.loadSample() }
            } label: {
                Image(systemName: "shippingbox")
            }
            .help("Load the sample project")

            Divider().frame(height: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(model.project?.name ?? "Stateglass")
                    .font(.system(size: 13, weight: .semibold))
                Text(model.project?.rootPath ?? "")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(Palette.muted)
                    .lineLimit(1)
            }
            .frame(maxWidth: 260, alignment: .leading)

            Spacer(minLength: 8)

            if !model.sessions.isEmpty {
                Picker("Run", selection: Binding(
                    get: { model.activeSession?.id ?? "" },
                    set: { id in
                        if let session = model.sessions.first(where: { $0.id == id }) {
                            Task { await model.selectSession(session) }
                        }
                    }
                )) {
                    ForEach(model.sessions) { session in
                        Text("\(session.kind == "experiment" ? "Experiment" : "Run") · \(session.status)")
                            .tag(session.id)
                    }
                }
                .labelsHidden()
                .frame(width: 165)
            }

            SettingsMenu()
            if model.isRunning {
                Button { Task { await model.cancelRun() } } label: {
                    Label("Cancel", systemImage: "stop.fill")
                }
                .buttonStyle(.bordered)
            } else {
                Button { Task { await model.run() } } label: {
                    Label("Run", systemImage: "play.fill")
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.return, modifiers: .command)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(Palette.panel)
        .overlay(alignment: .bottom) { Rectangle().fill(Palette.border).frame(height: 1) }
    }
}

private struct SettingsMenu: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        Menu {
            TextField("Arguments", text: $model.runArguments)
            TextField("Entry file", text: $model.entryPoint)
            TextField("Standard input", text: $model.runStdin)
            Stepper("Timeout: \(model.timeoutSeconds)s", value: $model.timeoutSeconds, in: 1...600)
            Toggle("Enable tracing", isOn: $model.tracingEnabled)
            TextField("Python interpreter (optional)", text: $model.pythonPath)
            Button("Save Run Settings") {
                Task {
                    do {
                        try await model.saveSettings()
                        model.notice = "Run settings saved"
                    } catch {
                        model.notice = error.localizedDescription
                    }
                }
            }
            Button("Save Global Python Path") { Task { await model.saveGlobalPythonPath() } }
        } label: {
            Image(systemName: "slider.horizontal.3")
                .frame(width: 28, height: 28)
        }
        .menuStyle(.borderlessButton)
        .help("Run settings")
    }
}

private struct ProjectSidebar: View {
    @EnvironmentObject private var model: AppModel
    @State private var filter = ""

    private var filteredFiles: [FileEntry] {
        guard !filter.isEmpty else { return model.files }
        return model.files.filter { $0.path.localizedCaseInsensitiveContains(filter) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("PROJECT").font(.system(size: 10, weight: .bold)).tracking(1.2)
                    .foregroundStyle(Palette.muted)
                Spacer()
                Button { Task { await model.refresh() } } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.plain)
                .help("Refresh project")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 11)

            TextField("Filter files", text: $filter)
                .textFieldStyle(.roundedBorder)
                .padding(.horizontal, 10)
                .padding(.bottom, 8)

            List(filteredFiles) { file in
                Button {
                    if !file.isDir { model.selectFile(file.path) }
                } label: {
                    HStack(spacing: 7) {
                        Image(systemName: file.isDir ? "folder" : file.isPython ? "curlybraces" : "doc.text")
                            .foregroundStyle(file.isDir ? Palette.accent : Palette.muted)
                            .frame(width: 14)
                        Text(file.name)
                            .lineLimit(1)
                            .foregroundStyle(file.path == model.selectedFile ? .white : Palette.muted)
                        if model.dirtyFiles.contains(file.path) {
                            Circle().fill(Palette.accent).frame(width: 5, height: 5)
                        }
                    }
                    .padding(.leading, CGFloat(max(0, file.path.split(separator: "/").count - 1)) * 10)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .listRowBackground(file.path == model.selectedFile ? Palette.raised : .clear)
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)

            Divider().overlay(Palette.border)
            VStack(alignment: .leading, spacing: 7) {
                Text("RECENT RUNS").font(.system(size: 10, weight: .bold)).tracking(1.2)
                    .foregroundStyle(Palette.muted)
                ForEach(model.sessions.prefix(5)) { session in
                    Button {
                        Task { await model.selectSession(session) }
                    } label: {
                        HStack(spacing: 7) {
                            Circle()
                                .fill(session.status == "ok" ? Palette.green : session.status == "running" ? Palette.accent : Palette.red)
                                .frame(width: 6, height: 6)
                            Text(session.command.isEmpty ? session.kind : session.command)
                                .lineLimit(1)
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(Palette.muted)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(12)
        }
        .background(Palette.panel)
    }
}

private struct CenterWorkspace: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 4) {
                ForEach(WorkspaceTab.allCases) { tab in
                    Button {
                        model.centerTab = tab
                    } label: {
                        Text(tab.rawValue)
                            .font(.system(size: 11, weight: model.centerTab == tab ? .semibold : .regular))
                            .foregroundStyle(model.centerTab == tab ? .white : Palette.muted)
                            .padding(.horizontal, 11)
                            .padding(.vertical, 8)
                            .background(model.centerTab == tab ? Palette.raised : .clear, in: RoundedRectangle(cornerRadius: 5))
                    }
                    .buttonStyle(.plain)
                }
                Spacer()
                if model.isDirty {
                    Button("Save") { Task { await model.saveFile() } }
                        .buttonStyle(.bordered)
                        .keyboardShortcut("s", modifiers: .command)
                }
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 6)
            .background(Palette.panel)

            Group {
                switch model.centerTab {
                case .editor: EditorPanel()
                case .flow: DataFlowPanel()
                case .compare: ComparePanel()
                case .experiments: ExperimentsPanel()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Palette.canvas)
        }
        .background(Palette.panel)
    }
}

private struct EditorPanel: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            if !model.openFilePaths.isEmpty {
                ScrollView(.horizontal) {
                    HStack(spacing: 2) {
                        ForEach(model.openFilePaths, id: \.self) { path in
                            Button {
                                model.selectFile(path)
                            } label: {
                                HStack(spacing: 6) {
                                    Text(URL(fileURLWithPath: path).lastPathComponent)
                                    if model.dirtyFiles.contains(path) { Circle().fill(Palette.accent).frame(width: 5, height: 5) }
                                }
                                .font(.system(size: 10))
                                .padding(.horizontal, 9)
                                .padding(.vertical, 7)
                                .background(model.selectedFile == path ? Palette.raised : .clear)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .scrollIndicators(.hidden)
                .background(Palette.panel)
            }
            if let selectedFile = model.selectedFile {
                HStack {
                    Text(selectedFile).font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(Palette.muted)
                    Spacer()
                    if model.isDirty { Text("Modified").foregroundStyle(Palette.accent) }
                }
                .font(.system(size: 10))
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                TextEditor(text: Binding(
                    get: { model.activeContent },
                    set: { model.updateEditor($0) }
                ))
                .font(.system(size: 12, design: .monospaced))
                .scrollContentBackground(.hidden)
                .padding(8)
                .background(Palette.canvas)
            } else {
                ContentUnavailableView("No file selected", systemImage: "doc.text", description: Text("Choose a source file from the project explorer."))
            }
        }
    }
}

private struct InspectorSidebar: View {
    @EnvironmentObject private var model: AppModel
    @State private var eventFilter = ""

    private var filteredEvents: [TraceEvent] {
        guard !eventFilter.isEmpty else { return model.traceEvents }
        return model.traceEvents.filter {
            $0.kind.localizedCaseInsensitiveContains(eventFilter)
                || ($0.name?.localizedCaseInsensitiveContains(eventFilter) ?? false)
                || ($0.functionName?.localizedCaseInsensitiveContains(eventFilter) ?? false)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("INSPECTOR").font(.system(size: 10, weight: .bold)).tracking(1.2)
                Spacer()
                if let session = model.activeSession {
                    Text(session.status.uppercased())
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(session.status == "ok" ? Palette.green : Palette.accent)
                }
            }
            .foregroundStyle(Palette.muted)
            .padding(11)

            VStack(alignment: .leading, spacing: 5) {
                Text("VARIABLES").font(.system(size: 9, weight: .bold)).tracking(1)
                    .foregroundStyle(Palette.muted)
                List(model.variables) { variable in
                    Button {
                        Task { await model.selectVariable(variable.name) }
                    } label: {
                        VStack(alignment: .leading, spacing: 3) {
                            HStack {
                                Text(variable.name).font(.system(size: 11, weight: .semibold, design: .monospaced))
                                Spacer()
                                Text(variable.vtype).font(.system(size: 9)).foregroundStyle(Palette.muted)
                            }
                            Text(variable.value).font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(Palette.muted)
                                .lineLimit(2)
                        }
                        .padding(.vertical, 3)
                    }
                    .buttonStyle(.plain)
                    .listRowBackground(model.selectedVariable == variable.name ? Palette.raised : .clear)
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)

                Divider().overlay(Palette.border)
                HStack {
                    Text("TIMELINE").font(.system(size: 9, weight: .bold)).tracking(1)
                    Spacer()
                    Text("\(model.traceEvents.count) events")
                }
                .font(.system(size: 9))
                .foregroundStyle(Palette.muted)

                TextField("Filter events", text: $eventFilter)
                    .textFieldStyle(.roundedBorder)
                List(filteredEvents) { event in
                    Button {
                        Task { await model.selectTrace(event) }
                    } label: {
                        HStack(spacing: 6) {
                            Text("#\(event.seq)").foregroundStyle(Palette.muted)
                            Text(event.kind).foregroundStyle(Palette.accent)
                            Text(event.name ?? event.functionName ?? event.file.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "")
                                .lineLimit(1)
                                .foregroundStyle(.white.opacity(0.8))
                        }
                        .font(.system(size: 9, design: .monospaced))
                        .padding(.vertical, 2)
                    }
                    .buttonStyle(.plain)
                    .listRowBackground(model.selectedTraceId == event.id ? Palette.raised : .clear)
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
            }
            .padding(.horizontal, 9)
            .frame(maxHeight: .infinity)

            if let selectedVariable = model.selectedVariable {
                Divider().overlay(Palette.border)
                VStack(alignment: .leading, spacing: 6) {
                    Text("\(selectedVariable) HISTORY")
                        .font(.system(size: 9, weight: .bold)).tracking(0.8)
                        .foregroundStyle(Palette.muted)
                    ForEach(model.variableHistory.prefix(5)) { item in
                        Text("#\(item.seq)  \(item.value ?? "")")
                            .font(.system(size: 9, design: .monospaced))
                            .lineLimit(1)
                    }
                }
                .padding(10)
            }
        }
        .background(Palette.panel)
    }
}

private struct DataFlowPanel: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        if let flow = model.dataFlow {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Value lineage · \(flow.variable)")
                        .font(.title3.bold())
                    Text(flow.note).font(.system(size: 11)).foregroundStyle(Palette.muted)
                    if flow.truncated {
                        Label("The trace was truncated; this graph may be incomplete.", systemImage: "exclamationmark.triangle")
                            .font(.system(size: 10))
                            .foregroundStyle(.orange)
                    }
                    ForEach(Array(flow.nodes.enumerated()), id: \.element.id) { index, node in
                        HStack(spacing: 10) {
                            Text("\(index + 1)").font(.system(size: 10, design: .monospaced)).foregroundStyle(Palette.muted)
                            VStack(alignment: .leading, spacing: 3) {
                                HStack {
                                    Text(node.label).font(.system(size: 11, weight: .semibold, design: .monospaced))
                                    Text(node.role.uppercased()).font(.system(size: 8, weight: .bold)).foregroundStyle(Palette.accent)
                                }
                                Text(node.value).font(.system(size: 10, design: .monospaced)).foregroundStyle(Palette.muted)
                                Text("\(node.file ?? "unknown"):\(node.line ?? 0) · \(node.funcName ?? "")")
                                    .font(.system(size: 9)).foregroundStyle(Palette.muted)
                            }
                            Spacer()
                            Text("#\(node.seq)").font(.system(size: 9, design: .monospaced)).foregroundStyle(Palette.muted)
                        }
                        .padding(10)
                        .background(Palette.panel, in: RoundedRectangle(cornerRadius: 7))
                        if let edge = flow.edges.first(where: { $0.target == node.id }) {
                            HStack(spacing: 5) {
                                Image(systemName: edge.kind == "update" ? "arrow.down" : "arrow.turn.down.right")
                                Text(edge.label)
                            }
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundStyle(Palette.accent)
                            .padding(.leading, 25)
                        }
                    }
                    Text("ASSIGNMENT SITES")
                        .font(.system(size: 9, weight: .bold)).tracking(1)
                        .foregroundStyle(Palette.muted)
                    ForEach(flow.assignmentSites) { assignment in
                        Text("\(assignment.file):\(assignment.line)  \(assignment.target) = \(assignment.sources.joined(separator: ", "))")
                            .font(.system(size: 10, design: .monospaced))
                            .padding(8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Palette.panel, in: RoundedRectangle(cornerRadius: 5))
                    }
                }
                .padding(16)
            }
        } else {
            ContentUnavailableView("Select a variable", systemImage: "point.3.connected.trianglepath.dotted", description: Text("Choose a variable in the inspector to inspect its data flow."))
        }
    }
}

private struct ComparePanel: View {
    @EnvironmentObject private var model: AppModel
    @State private var baselineId = ""
    @State private var experimentId = ""

    private var baselines: [Session] { model.sessions.filter { $0.kind == "baseline" && $0.status != "running" } }
    private var experiments: [Session] { model.sessions.filter { $0.kind == "experiment" && $0.status != "running" } }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Picker("Baseline", selection: $baselineId) {
                    ForEach(baselines) { session in
                        Text(session.command).lineLimit(1).tag(session.id)
                    }
                }
                Picker("Experiment", selection: $experimentId) {
                    ForEach(experiments) { session in
                        Text(session.label ?? session.command).lineLimit(1).tag(session.id)
                    }
                }
                Button("Compare") {
                    guard let left = model.sessions.first(where: { $0.id == baselineId }),
                          let right = model.sessions.first(where: { $0.id == experimentId }) else { return }
                    Task { await model.compare(left, right) }
                }
                .buttonStyle(.borderedProminent)
            }
            .pickerStyle(.menu)

            if let comparison = model.comparison {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        HStack(spacing: 18) {
                            metric("Baseline", comparison.baselineMetrics)
                            metric("Experiment", comparison.experimentMetrics)
                            if let line = comparison.stdoutDivergence { Text("First output change · line \(line)").foregroundStyle(Palette.accent) }
                        }
                        if !comparison.warnings.isEmpty {
                            ForEach(comparison.warnings, id: \.self) { warning in
                                Label(warning, systemImage: "info.circle").font(.system(size: 10)).foregroundStyle(.orange)
                            }
                        }
                        Text("STDOUT DIFF").font(.system(size: 9, weight: .bold)).tracking(1).foregroundStyle(Palette.muted)
                        ForEach(comparison.stdout) { line in diffRow(line) }
                        Text("STDERR DIFF").font(.system(size: 9, weight: .bold)).tracking(1).foregroundStyle(Palette.muted)
                        ForEach(comparison.stderr) { line in diffRow(line) }
                        Text("VARIABLES").font(.system(size: 9, weight: .bold)).tracking(1).foregroundStyle(Palette.muted)
                        ForEach(comparison.variables) { item in
                            HStack {
                                Text(item.name).font(.system(size: 10, design: .monospaced))
                                Text(item.baselineValue ?? "—").foregroundStyle(Palette.muted)
                                Image(systemName: "arrow.right").foregroundStyle(Palette.muted)
                                Text(item.experimentValue ?? "—")
                                Spacer()
                                Text(item.status.uppercased()).font(.system(size: 8, weight: .bold)).foregroundStyle(item.status == "same" ? Palette.green : Palette.accent)
                            }
                            .font(.system(size: 10, design: .monospaced))
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                }
            } else {
                ContentUnavailableView("Compare executions", systemImage: "arrow.left.arrow.right", description: Text("Choose a baseline and an experiment execution to view output and variable changes."))
                Spacer()
            }
        }
        .padding(12)
        .onAppear {
            baselineId = baselines.first?.id ?? ""
            experimentId = experiments.first?.id ?? ""
        }
    }

    private func metric(_ title: String, _ metrics: RunMetrics) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title.uppercased()).font(.system(size: 8, weight: .bold)).foregroundStyle(Palette.muted)
            Text("\(metrics.status) · \(metrics.durationMs ?? 0) ms · exit \(metrics.exitCode.map(String.init) ?? "—")")
                .font(.system(size: 10, design: .monospaced))
        }
    }

    private func diffRow(_ line: DiffLine) -> some View {
        Text(line.text.isEmpty ? " " : line.text)
            .font(.system(size: 10, design: .monospaced))
            .foregroundStyle(line.kind == "add" ? Palette.green : line.kind == "remove" ? Palette.red : Palette.muted)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 6)
            .background(line.kind == "add" ? Palette.green.opacity(0.08) : line.kind == "remove" ? Palette.red.opacity(0.08) : .clear)
    }
}

private struct ExperimentsPanel: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Experiments").font(.title3.bold())
                    Text("Each experiment is an isolated copy of the project.")
                        .font(.system(size: 10)).foregroundStyle(Palette.muted)
                }
                Spacer()
                Button("New Experiment…") { model.showNewExperiment = true }
                    .buttonStyle(.borderedProminent)
            }
            List(model.experiments) { experiment in
                HStack(spacing: 10) {
                    Image(systemName: "testtube.2").foregroundStyle(Palette.accent)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(experiment.name).font(.system(size: 12, weight: .semibold))
                        Text(experiment.note ?? experiment.path)
                            .font(.system(size: 9)).foregroundStyle(Palette.muted).lineLimit(1)
                    }
                    Spacer()
                    Button("Open Copy") { Task { await model.selectExperiment(experiment.id) } }
                        .buttonStyle(.bordered)
                    Button("Run") { Task { await model.runExperiment(experiment) } }
                        .buttonStyle(.borderedProminent)
                }
                .padding(.vertical, 4)
                .listRowBackground(Palette.panel)
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
        }
        .padding(12)
    }
}

private struct NewExperimentSheet: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("New Experiment").font(.title2.bold())
            Text("Create an isolated copy based on the most recent completed baseline run.")
                .font(.system(size: 11)).foregroundStyle(Palette.muted)
            TextField("Experiment name", text: $model.experimentName)
            TextField("Note (optional)", text: $model.experimentNote)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Create") { Task { await model.createExperiment() } }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.experimentName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
    }
}

private struct ConsolePanel: View {
    @EnvironmentObject private var model: AppModel
    @State private var showingStderr = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("CONSOLE").font(.system(size: 9, weight: .bold)).tracking(1)
                Button("stdout") { showingStderr = false }
                    .buttonStyle(.plain)
                    .foregroundStyle(showingStderr ? Palette.muted : Palette.accent)
                Button("stderr") { showingStderr = true }
                    .buttonStyle(.plain)
                    .foregroundStyle(showingStderr ? Palette.accent : Palette.muted)
                Spacer()
                if let runStats = model.runStats {
                    Text("Elapsed \(runStats)").foregroundStyle(Palette.muted)
                }
            }
            .font(.system(size: 9))
            .foregroundStyle(Palette.muted)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            ScrollView {
                Text(showingStderr ? model.stderr : model.output)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(showingStderr ? Palette.red.opacity(0.9) : .white.opacity(0.82))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
            }
        }
        .background(Palette.panel)
    }
}

private struct StatusBar: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(model.isRunning ? Palette.accent : model.activeSession?.status == "ok" ? Palette.green : Palette.muted)
                .frame(width: 6, height: 6)
            Text(model.isRunning ? "Running" : model.activeSession?.status.capitalized ?? "Ready")
            if let activeSession = model.activeSession {
                Text(activeSession.command).lineLimit(1).foregroundStyle(Palette.muted)
            }
            Spacer()
            if model.isBusy { ProgressView().controlSize(.small) }
            Text("⌘O Open  ·  ⌘S Save  ·  ⌘↵ Run")
                .foregroundStyle(Palette.muted)
        }
        .font(.system(size: 9, design: .monospaced))
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Palette.panel)
    }
}
