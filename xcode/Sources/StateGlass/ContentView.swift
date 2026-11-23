import SwiftUI
import AppKit

private enum Palette {
    static let canvas = GlassTheme.canvas
    static let panel = GlassTheme.panel
    static let raised = GlassTheme.raised
    static let border = GlassTheme.border
    static let accent = GlassTheme.accent
    static let muted = GlassTheme.muted
    static let green = GlassTheme.green
    static let red = GlassTheme.red
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
                    AppIcon("alert", size: 36)
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
        .onChange(of: model.centerTab) { _, tab in
            UserDefaults.standard.set(tab.rawValue, forKey: "centerTab")
        }
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
            AppIcon("logo", size: 48)
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
                                AppIcon("folder", size: 14)
                                VStack(alignment: .leading) {
                                    Text(project.name)
                                    Text(project.rootPath).font(.system(size: 9, design: .monospaced)).foregroundStyle(Palette.muted)
                                }
                                Spacer()
                                AppIcon("chevron-right", size: 10).foregroundStyle(Palette.muted)
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
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @SceneStorage("workspace.inspectorVisible") private var showInspector = true
    @State private var quickLookURL: URL?

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            ProjectSidebar(quickLookURL: $quickLookURL)
                .navigationSplitViewColumnWidth(
                    min: GlassMetrics.sidebarMin,
                    ideal: GlassMetrics.sidebarIdeal,
                    max: GlassMetrics.sidebarMax
                )
        } detail: {
            VStack(spacing: 0) {
                VSplitView {
                    CenterWorkspace()
                        .frame(minWidth: 420, minHeight: 260)
                    ConsolePanel()
                        .frame(minHeight: GlassMetrics.consoleMin, idealHeight: GlassMetrics.consoleIdeal)
                }
                StatusBar()
            }
            .navigationTitle(model.project?.name ?? "Stateglass")
            .navigationSubtitle(model.project?.rootPath ?? "")
            .toolbar { toolbar }
        }
        .inspector(isPresented: $showInspector) {
            InspectorSidebar()
                .inspectorColumnWidth(
                    min: GlassMetrics.inspectorMin,
                    ideal: GlassMetrics.inspectorIdeal,
                    max: GlassMetrics.inspectorMax
                )
        }
        .onChange(of: quickLookURL) { _, url in
            guard let url else { return }
            QuickLookController.shared.preview(url)
            quickLookURL = nil
        }
        .dropDestination(for: URL.self) { urls, _ in
            guard let folder = urls.first else { return false }
            Task { await model.openProjectFromURL(folder) }
            return true
        }
        .background(GlassTheme.canvas)
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            Button(action: model.openProjectPanel) {
                IconLabel("Open", icon: "folder")
            }
            .help("Open a project folder (⌘O)")
            .accessibilityLabel("Open project")
        }
        ToolbarItem(placement: .navigation) {
            Button { Task { await model.loadSample() } } label: {
                IconLabel("Sample", icon: "box")
            }
            .help("Load the sample project")
            .accessibilityLabel("Load sample project")
        }
        ToolbarItemGroup(placement: .primaryAction) {
            if !model.sessions.isEmpty {
                Picker("Run", selection: sessionBinding) {
                    ForEach(model.sessions) { session in
                        Text("\(session.kind == "experiment" ? "Experiment" : "Run") · \(session.status)")
                            .tag(session.id)
                    }
                }
                .labelsHidden()
                .frame(width: 165)
                .help("Select a recorded run")
                .accessibilityLabel("Select a recorded run")
            }
            SettingsLink {
                IconLabel("Run Settings", icon: "sliders")
            }
            .help("Run settings")
            if let root = model.project?.rootPath {
                ShareLink(item: URL(fileURLWithPath: root)) {
                    IconLabel("Share", icon: "share")
                }
                .help("Share the project folder")
            }
            if model.isRunning {
                Button { Task { await model.cancelRun() } } label: {
                    IconLabel("Cancel", icon: "stop")
                }
                .help("Cancel the running project (⌘.)")
            } else {
                Button { Task { await model.run() } } label: {
                    IconLabel("Run", icon: "play")
                }
                .buttonStyle(.borderedProminent)
                .help("Run the project (⌘↵)")
            }
            Button { showInspector.toggle() } label: {
                IconLabel("Inspector", icon: "panel-right")
            }
            .help("Show or hide the inspector")
        }
    }

    private var sessionBinding: Binding<String> {
        Binding(
            get: { model.activeSession?.id ?? "" },
            set: { id in
                if let session = model.sessions.first(where: { $0.id == id }) {
                    Task { await model.selectSession(session) }
                }
            }
        )
    }
}

private struct ProjectSidebar: View {
    @EnvironmentObject private var model: AppModel
    @Binding var quickLookURL: URL?
    @State private var filter = ""

    private var filteredFiles: [FileEntry] {
        guard !filter.isEmpty else { return model.files }
        return model.files.filter {
            $0.path.localizedCaseInsensitiveContains(filter)
                || $0.name.localizedCaseInsensitiveContains(filter)
        }
    }

    private var rootURL: URL? {
        model.project.map { URL(fileURLWithPath: $0.rootPath) }
    }

    var body: some View {
        List {
            Section {
                ForEach(filteredFiles) { file in
                    fileRow(file)
                }
            } header: {
                HStack {
                    Text("Project")
                    Spacer()
                    Button { Task { await model.refresh() } } label: {
                        AppIcon("refresh", size: 13)
                    }
                    .buttonStyle(.borderless)
                    .help("Refresh project")
                    .accessibilityLabel("Refresh project")
                }
            }

            if !model.sessions.isEmpty {
                Section("Recent Runs") {
                    ForEach(model.sessions.prefix(5)) { session in
                        Button { Task { await model.selectSession(session) } } label: {
                            HStack(spacing: 7) {
                                Circle()
                                    .fill(statusColor(session.status))
                                    .frame(width: 6, height: 6)
                                Text(session.command.isEmpty ? session.kind : session.command)
                                    .font(.caption.monospaced())
                                    .lineLimit(1)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Run \(session.command), status \(session.status)")
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .searchable(text: $filter, placement: .sidebar, prompt: "Filter files")
        .accessibilityLabel("Project files")
    }

    @ViewBuilder
    private func fileRow(_ file: FileEntry) -> some View {
        let isSelected = file.path == model.selectedFile
        Button {
            if !file.isDir { model.selectFile(file.path) }
        } label: {
            HStack(spacing: 7) {
                AppIcon(
                    file.isDir ? "folder" : (file.isPython ? "code" : "file"),
                    size: 14
                )
                    .foregroundStyle(file.isDir ? GlassTheme.accent : GlassTheme.muted)
                    .frame(width: 14)
                Text(file.name)
                    .lineLimit(1)
                if model.dirtyFiles.contains(file.path) {
                    Circle().fill(GlassTheme.accent).frame(width: 5, height: 5)
                }
                Spacer(minLength: 0)
            }
            .padding(.leading, CGFloat(max(0, file.path.split(separator: "/").count - 1)) * 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .listRowBackground(isSelected ? GlassTheme.raised : .clear)
        .accessibilityLabel(file.name)
        .accessibilityHint(file.isDir ? "Folder" : "Opens the file in the editor")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .contextMenu { contextMenu(for: file) }
        .onDrag { dragProvider(for: file) }
    }

    @ViewBuilder
    private func contextMenu(for file: FileEntry) -> some View {
        if !file.isDir {
            Button("Open") { model.selectFile(file.path) }
            Button("Quick Look") { quickLookURL = url(for: file) }
        }
        if let url = url(for: file) {
            Button("Reveal in Finder") { FileActions.reveal(url) }
            Button("Copy Path") { FileActions.copyPath(url) }
        }
    }

    private func url(for file: FileEntry) -> URL? {
        rootURL?.appendingPathComponent(file.path)
    }

    private func dragProvider(for file: FileEntry) -> NSItemProvider {
        guard let url = url(for: file) else { return NSItemProvider() }
        return NSItemProvider(contentsOf: url) ?? NSItemProvider()
    }

    private func statusColor(_ status: String) -> Color {
        switch status {
        case "ok": GlassTheme.green
        case "running": GlassTheme.accent
        default: GlassTheme.red
        }
    }
}

private struct CenterWorkspace: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Picker("Workspace", selection: $model.centerTab) {
                    ForEach(WorkspaceTab.allCases) { tab in
                        Text(tab.rawValue).tag(tab)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .accessibilityLabel("Workspace view")
                Spacer()
                if model.isDirty {
                    Button("Save") { Task { await model.saveFile() } }
                        .buttonStyle(.bordered)
                        .keyboardShortcut("s", modifiers: .command)
                        .help("Save the current file (⌘S)")
                }
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 6)
            .background(Palette.panel)

            Group {
                switch model.centerTab {
                case .canvas: CanvasView()
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
                CodeEditor(text: Binding(
                    get: { model.activeContent },
                    set: { model.updateEditor($0) }
                ))
                .accessibilityLabel("Source editor for \(selectedFile)")
                .background(Palette.canvas)
            } else {
                ContentUnavailableView {
                    Label {
                        Text("No file selected")
                    } icon: {
                        AppIcon("file", size: 44)
                    }
                } description: {
                    Text("Choose a source file from the project explorer.")
                }
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
                    .accessibilityLabel("\(variable.name), type \(variable.vtype), value \(variable.value)")
                    .accessibilityAddTraits(model.selectedVariable == variable.name ? .isSelected : [])
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
                                .foregroundStyle(.secondary)
                        }
                        .font(.system(size: 9, design: .monospaced))
                        .padding(.vertical, 2)
                    }
                    .buttonStyle(.plain)
                    .listRowBackground(model.selectedTraceId == event.id ? Palette.raised : .clear)
                    .accessibilityLabel("Event \(event.seq), \(event.kind), \(event.name ?? event.functionName ?? "")")
                    .accessibilityAddTraits(model.selectedTraceId == event.id ? .isSelected : [])
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
                        IconLabel("The trace was truncated; this graph may be incomplete.", icon: "alert", size: 12)
                            .font(.system(size: 10))
                            .foregroundStyle(.orange)
                    }
                    FlowGraphView(flow: flow)
                        .frame(minHeight: 280)
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
            ContentUnavailableView {
                Label {
                    Text("Select a variable")
                } icon: {
                    AppIcon("flow", size: 44)
                }
            } description: {
                Text("Choose a variable in the inspector to inspect its data flow.")
            }
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
                                IconLabel(warning, icon: "info", size: 11).font(.system(size: 10)).foregroundStyle(.orange)
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
                                AppIcon("arrow-right", size: 11).foregroundStyle(Palette.muted)
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
                ContentUnavailableView {
                    Label {
                        Text("Compare executions")
                    } icon: {
                        AppIcon("compare", size: 44)
                    }
                } description: {
                    Text("Choose a baseline and an experiment execution to view output and variable changes.")
                }
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
                    AppIcon("experiment", size: 16).foregroundStyle(Palette.accent)
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
                    .foregroundStyle(showingStderr ? Palette.red.opacity(0.9) : Color.primary.opacity(0.82))
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
