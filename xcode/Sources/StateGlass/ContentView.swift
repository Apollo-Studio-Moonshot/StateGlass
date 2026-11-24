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

/// The previous default frame was 1500×940. Shrink that restored window once
/// so the larger type sits in a window of the same scale.
private struct WindowBalance: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { BalanceView() }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

private final class BalanceView: NSView {
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        let key = "window.balancedFrame"
        guard let window, !UserDefaults.standard.bool(forKey: key) else { return }
        UserDefaults.standard.set(true, forKey: key)
        let size = window.frame.size
        guard size.width > 1280 || size.height > 820 else { return }
        var frame = window.frame
        let next = NSSize(width: 1120, height: 720)
        frame.origin.y += frame.height - next.height
        frame.size = next
        window.setFrame(frame, display: true, animate: false)
    }
}

struct ContentView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

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
        .background(WindowBalance())
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
        .confirmationDialog(
            "Discard unsaved changes?",
            isPresented: Binding(
                get: { model.closePrompt != nil },
                set: { if !$0 { model.closePrompt = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Discard Changes", role: .destructive) { model.confirmDiscardClose() }
            Button("Cancel", role: .cancel) { model.closePrompt = nil }
        } message: {
            if let path = model.closePrompt {
                Text("\(URL(fileURLWithPath: path).lastPathComponent) has unsaved edits.")
            }
        }
        .overlay {
            if let kind = model.palette {
                CommandPalette(kind: kind)
                    .transition(.opacity)
            }
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: model.palette)
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
                    Text("Recent")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Palette.muted)
                    ForEach(model.projects) { project in
                        Button {
                            Task { await model.openRecentProject(project) }
                        } label: {
                            HStack {
                                AppIcon("folder", size: 14)
                                VStack(alignment: .leading) {
                                    Text(project.name)
                                    Text(project.rootPath).font(.system(size: 12, design: .monospaced)).foregroundStyle(Palette.muted)
                                }
                                Spacer()
                                AppIcon("chevron-right", size: 10).foregroundStyle(Palette.muted)
                            }
                            .font(.system(size: 13))
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
        .inspector(isPresented: $model.showInspector) {
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
        .onChange(of: model.showInspector) { _, shown in
            UserDefaults.standard.set(shown, forKey: "workspace.inspectorVisible")
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
            Button { model.showInspector.toggle() } label: {
                IconLabel("Inspector", icon: "panel-right")
            }
            .help("Show or hide the inspector (⌘⌥I)")
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
                                    .font(.system(size: 12, design: .monospaced))
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
                AppIcon(FileIcons.name(for: file.path, isDir: file.isDir), size: 14)
                    .foregroundStyle(file.isDir ? GlassTheme.accent : GlassTheme.muted)
                    .frame(width: 14)
                Text(file.name)
                    .lineLimit(1)
                if model.dirtyFiles.contains(file.path) {
                    Circle().fill(GlassTheme.accent).frame(width: 5, height: 5)
                }
                Spacer(minLength: 0)
            }
            .padding(.leading, CGFloat(max(0, file.path.split(separator: "/").count - 1)) * 12)
            .font(.system(size: 13))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .listRowInsets(EdgeInsets(top: 3, leading: 10, bottom: 3, trailing: 10))
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
                .frame(maxWidth: 460)
                .accessibilityLabel("Workspace view")
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(GlassTheme.chrome)

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
    @State private var hoveredTab: String?

    var body: some View {
        VStack(spacing: 0) {
            if !model.openFilePaths.isEmpty {
                ScrollView(.horizontal) {
                    HStack(spacing: 0) {
                        ForEach(model.openFilePaths, id: \.self) { path in
                            editorTab(path)
                        }
                    }
                }
                .scrollIndicators(.hidden)
                .background(GlassTheme.chrome)
                Divider()
            }
            if let selectedFile = model.selectedFile {
                breadcrumb(selectedFile)
                CodeEditor(
                    text: Binding(
                        get: { model.activeContent },
                        set: { model.updateEditor($0) }
                    ),
                    language: model.editorLanguage,
                    traceLine: model.revealLine,
                    revealToken: model.revealToken,
                    onCursorChange: { line, column in
                        model.updateCursor(line: line, column: column)
                    }
                )
                .accessibilityLabel("Source editor for \(selectedFile)")
                .background(GlassTheme.editor)
            } else {
                ContentUnavailableView {
                    Label {
                        Text("No file open")
                    } icon: {
                        AppIcon("file", size: 44)
                    }
                } description: {
                    Text("Choose a file from the sidebar, or press ⌘P.")
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(GlassTheme.editor)
            }
        }
        .background(GlassTheme.editor)
    }

    private func editorTab(_ path: String) -> some View {
        let selected = model.selectedFile == path
        let dirty = model.dirtyFiles.contains(path)
        let name = URL(fileURLWithPath: path).lastPathComponent
        return HStack(spacing: 6) {
            Button {
                model.selectFile(path)
            } label: {
                HStack(spacing: 6) {
                    AppIcon(FileIcons.name(for: path, isDir: false), size: 14)
                        .foregroundStyle(selected ? Color.accentColor : .secondary)
                    Text(name)
                        .lineLimit(1)
                }
                .font(.system(size: 13))
                .foregroundStyle(selected ? Color.primary : .secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(dirty ? "\(name), unsaved" : name)
            .accessibilityAddTraits(selected ? .isSelected : [])

            Button {
                model.requestClose(path)
            } label: {
                ZStack {
                    if dirty && hoveredTab != path {
                        Circle().fill(Color.accentColor).frame(width: 6, height: 6)
                    } else {
                        AppIcon("close", size: 11)
                            .foregroundStyle(.secondary)
                            .opacity(hoveredTab == path || selected ? 1 : 0)
                    }
                }
                .frame(width: 16, height: 16)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close \(name)")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(selected ? GlassTheme.editor : Color.clear)
        .onHover { hovering in
            hoveredTab = hovering ? path : (hoveredTab == path ? nil : hoveredTab)
        }
    }

    private func breadcrumb(_ path: String) -> some View {
        let parts = path.split(separator: "/").map(String.init)
        return HStack(spacing: 4) {
            ForEach(Array(parts.enumerated()), id: \.offset) { index, part in
                Text(part)
                    .foregroundStyle(index == parts.count - 1 ? Color.primary : Color.secondary)
                if index < parts.count - 1 {
                    AppIcon("chevron-right", size: 10)
                        .foregroundStyle(.tertiary)
                }
            }
            if let line = model.revealLine {
                Text(":\(line)")
                    .foregroundStyle(GlassTheme.warning)
            }
            Spacer(minLength: 0)
        }
        .font(.system(size: 13))
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .background(GlassTheme.editor)
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
                Text("Inspector").font(.system(size: 13, weight: .semibold))
                Spacer()
                if let session = model.activeSession {
                    Text(session.status.uppercased())
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(session.status == "ok" ? Palette.green : Palette.accent)
                }
            }
            .foregroundStyle(Palette.muted)
            .padding(11)

            VStack(alignment: .leading, spacing: 5) {
                Text("Variables").font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Palette.muted)
                List(model.variables) { variable in
                    Button {
                        Task { await model.selectVariable(variable.name) }
                    } label: {
                        VStack(alignment: .leading, spacing: 3) {
                            HStack {
                                Text(variable.name).font(.system(size: 13, weight: .semibold, design: .monospaced))
                                Spacer()
                                Text(variable.vtype).font(.system(size: 12)).foregroundStyle(Palette.muted)
                            }
                            Text(variable.value).font(.system(size: 12, design: .monospaced))
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
                    Text("Timeline").font(.system(size: 13, weight: .semibold))
                    Spacer()
                    Text("\(model.traceEvents.count) events")
                }
                .font(.system(size: 12))
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
                        .font(.system(size: 12, design: .monospaced))
                        .padding(.vertical, 3)
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
                    Text("\(selectedVariable) history")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Palette.muted)
                    ForEach(model.variableHistory.prefix(5)) { item in
                        Text("#\(item.seq)  \(item.value ?? "")")
                            .font(.system(size: 12, design: .monospaced))
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
            HStack(spacing: 10) {
                Text("Console")
                    .font(.system(size: 13, weight: .semibold))
                Picker("Stream", selection: $showingStderr) {
                    Text("stdout").tag(false)
                    Text("stderr").tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .controlSize(.small)
                .frame(width: 148)
                Spacer()
                if let runStats = model.runStats {
                    Text(runStats).foregroundStyle(Palette.muted)
                }
            }
            .font(.system(size: 13))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            ScrollView {
                Text(showingStderr ? model.stderr : model.output)
                    .font(.system(size: 13, design: .monospaced))
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
        HStack(spacing: 0) {
            HStack(spacing: 6) {
                Circle()
                    .fill(model.isRunning ? Palette.accent : model.activeSession?.status == "ok" ? Palette.green : Palette.muted)
                    .frame(width: 6, height: 6)
                Text(model.isRunning ? "Running" : model.activeSession?.status.capitalized ?? "Ready")
                if let activeSession = model.activeSession {
                    Text(activeSession.command)
                        .lineLimit(1)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 8)
            if model.isBusy { ProgressView().controlSize(.mini) }
            if let note = model.statusNote {
                statusItem(note)
            }
            if model.selectedFile != nil {
                statusItem(model.editorLanguageLabel)
                statusItem("Indent: 4")
                statusItem("Ln \(model.editorLine), Col \(model.editorColumn)")
            }
        }
        .font(.system(size: 12))
        .padding(.leading, 12)
        .padding(.trailing, 6)
        .frame(height: 28)
        .background(GlassTheme.chrome)
        .overlay(alignment: .top) { Divider() }
    }

    private func statusItem(_ title: String) -> some View {
        Text(title)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .padding(.horizontal, 8)
            .frame(height: 28)
    }
}
