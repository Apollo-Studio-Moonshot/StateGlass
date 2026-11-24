import Combine
import Foundation
import AppKit

enum WorkspaceTab: String, CaseIterable, Identifiable {
    case canvas = "Canvas"
    case editor = "Editor"
    case flow = "Data Flow"
    case compare = "Compare"
    case experiments = "Experiments"
    var id: String { rawValue }
}

private struct RunOutputMessage: Decodable {
    let sessionId: String
    let stream: String
    let chunk: String
}

private struct RunTraceMessage: Decodable {
    let sessionId: String
    let events: [TraceEvent]
    let total: Int64
}

private struct WorkspaceChangedMessage: Decodable {
    let workspaceId: String
}

@MainActor
final class AppModel: ObservableObject {
    /// Shared instance used by App Intents, the Dock menu, and Services.
    static let shared = AppModel()

    @Published private(set) var booting = true
    @Published private(set) var bootError: String?
    @Published private(set) var projects: [Project] = []
    @Published private(set) var project: Project?
    @Published private(set) var files: [FileEntry] = []
    @Published private(set) var sessions: [Session] = []
    @Published private(set) var experiments: [Experiment] = []
    @Published private(set) var activeSession: Session?
    @Published private(set) var traceEvents: [TraceEvent] = []
    @Published private(set) var variables: [VariableSnapshot] = []
    @Published private(set) var variableHistory: [TraceEvent] = []
    @Published private(set) var dataFlow: DataFlow?
    @Published private(set) var comparison: SessionComparison?
    @Published private(set) var output = ""
    @Published private(set) var stderr = ""
    @Published private(set) var selectedFile: String?
    @Published private(set) var selectedExperimentId: String?
    @Published private(set) var selectedVariable: String?
    @Published private(set) var selectedTraceId: Int64?
    @Published private(set) var dirtyFiles: Set<String> = []
    @Published private(set) var isBusy = false
    @Published var notice: String?
    @Published var centerTab: WorkspaceTab = .editor
    @Published private(set) var canvasNodes: [ContextNode] = []
    @Published private(set) var canvasDependencies: [NodeDependency] = []
    @Published var selectedNodeIDs: Set<String> = []
    @Published var focusedNodeID: String?
    @Published var canvasMode: CanvasMode = .build
    @Published var bottleneck = 0.5
    @Published var runArguments = ""
    @Published var entryPoint = ""
    @Published var timeoutSeconds = 30
    @Published var tracingEnabled = true
    @Published var pythonPath = ""
    @Published var runStdin = ""
    @Published var showConsent = false
    @Published var showNewExperiment = false
    @Published var experimentName = ""
    @Published var experimentNote = ""
    @Published var settingsError: String?
    @Published var runStats: String?
    @Published var showInspector = UserDefaults.standard.object(forKey: "workspace.inspectorVisible") as? Bool ?? true
    @Published var palette: PaletteKind?
    @Published var closePrompt: String?
    @Published private(set) var editorLine = 1
    @Published private(set) var editorColumn = 1
    @Published private(set) var revealLine: Int?
    @Published private(set) var revealToken = 0
    @Published var statusNote: String?

    private let client = SidecarClient()
    private let canvasClient = CanvasBackendClient()
    private var canvasLoaded = false
    private var buffers: [String: String] = [:]
    private var savedBuffers: [String: String] = [:]
    private var openOrder: [String] = []
    private var eventTask: Task<Void, Never>?

    var activeContent: String {
        guard let selectedFile else { return "" }
        return buffers[selectedFile] ?? ""
    }

    var openFilePaths: [String] {
        openOrder
    }

    var editorLanguage: String {
        selectedFile.map(SourceLanguage.id(for:)) ?? "text"
    }

    var editorLanguageLabel: String {
        SourceLanguage.label(for: editorLanguage)
    }

    var isDirty: Bool {
        guard let selectedFile else { return false }
        return dirtyFiles.contains(selectedFile)
    }

    var isRunning: Bool {
        activeSession?.status == "running"
    }

    var displayRoot: String {
        project?.rootPath ?? ""
    }

    var focusedCanvasNode: ContextNode? {
        canvasNodes.first { $0.id == focusedNodeID }
    }

    func loadCanvasIfNeeded() async {
        guard !canvasLoaded else { return }
        await loadCanvas()
    }

    func loadCanvas() async {
        do {
            let snapshot: CanvasSnapshot = try await canvasClient.request("list_canvas")
            canvasNodes = snapshot.nodes
            canvasDependencies = snapshot.dependencies
            canvasLoaded = true
            if focusedNodeID == nil {
                focusedNodeID = snapshot.nodes.first?.id
            }
        } catch {
            notice = error.localizedDescription
        }
    }

    func addCanvasNode(_ kind: ContextNodeKind) async {
        do {
            let node: ContextNode = try await canvasClient.request("add_node", params: [
                "kind": kind.rawValue,
                "title": kind.title,
            ])
            canvasNodes.append(node)
            focusedNodeID = node.id
            selectedNodeIDs = [node.id]
        } catch {
            notice = error.localizedDescription
        }
    }

    func updateCanvasNode(_ node: ContextNode) async {
        do {
            let updated: ContextNode = try await canvasClient.request("update_node", params: [
                "id": node.id,
                "title": node.title,
                "summary": node.summary,
                "status": node.status.rawValue,
            ])
            replaceCanvasNode(updated)
            await loadCanvas()
        } catch {
            notice = error.localizedDescription
        }
    }

    func addCanvasDependency(from sourceID: String, to targetID: String) async {
        do {
            let dependency: NodeDependency = try await canvasClient.request("add_dependency", params: [
                "sourceId": sourceID,
                "targetId": targetID,
            ])
            canvasDependencies.append(dependency)
        } catch {
            notice = error.localizedDescription
        }
    }

    func removeCanvasDependency(_ dependency: NodeDependency) async {
        do {
            let _: Bool = try await canvasClient.request("remove_dependency", params: [
                "id": dependency.id,
            ])
            canvasDependencies.removeAll { $0.id == dependency.id }
        } catch {
            notice = error.localizedDescription
        }
    }

    func focusCanvasNode(_ node: ContextNode) {
        focusedNodeID = node.id
        selectedNodeIDs = [node.id]
    }

    private func replaceCanvasNode(_ node: ContextNode) {
        guard let index = canvasNodes.firstIndex(where: { $0.id == node.id }) else { return }
        canvasNodes[index] = node
    }

    func start() async {
        booting = true
        bootError = nil
        do {
            try client.start()
            if eventTask == nil {
                eventTask = Task { [weak self, events = client.events] in
                    for await event in events {
                        self?.receive(event)
                    }
                }
            }
            let boot: Bootstrap = try await request("bootstrap")
            _ = boot
            if let raw = UserDefaults.standard.string(forKey: "centerTab"),
               let tab = WorkspaceTab(rawValue: raw) {
                centerTab = tab
            }
            try await loadProjects()
            if let initialPath = ProcessInfo.processInfo.environment["STATEGLASS_PROJECT_PATH"] {
                try await openProject(path: initialPath)
            } else if let lastPath = UserDefaults.standard.string(forKey: "recentProjectPath"),
                      FileManager.default.fileExists(atPath: lastPath) {
                try await openProject(path: lastPath)
            }
        } catch {
            bootError = error.localizedDescription
        }
        booting = false
    }

    func openProject(path: String) async throws {
        let opened: Project = try await request("open_project", params: ["path": path])
        setProject(opened)
        UserDefaults.standard.set(opened.rootPath, forKey: "recentProjectPath")
        try await refreshWorkspace()
    }

    func openProjectPanel() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Open Project"
        if panel.runModal() == .OK, let url = panel.url {
            Task { await runAction { try await self.openProject(path: url.path) } }
        }
    }

    func loadSample() async {
        await runAction {
            let opened: Project = try await self.request("create_sample_project")
            self.setProject(opened)
            try await self.refreshWorkspace()
        }
    }

    func loadProjects() async throws {
        projects = try await request("list_projects")
    }

    func openRecentProject(_ project: Project) async {
        await runAction { try await self.openProject(path: project.rootPath) }
    }

    /// Entry point for Finder drops, Services, Handoff, and App Intents.
    func openProjectFromURL(_ url: URL) async {
        await runAction { try await self.openProject(path: url.path) }
    }

    func openProjectFromIntent(path: String) async {
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        await openProjectFromURL(url)
    }

    func refresh() async {
        await runAction { try await self.refreshWorkspace() }
    }

    func refreshWorkspace() async throws {
        guard let project else { return }
        async let listedFiles: [FileEntry] = request("list_files", params: [
            "projectId": project.id,
            "experimentId": selectedExperimentId ?? NSNull(),
        ])
        async let listedExperiments: [Experiment] = request("list_experiments", params: [
            "projectId": project.id,
        ])
        async let listedSessions: [Session] = request("list_sessions", params: [
            "projectId": project.id,
            "limit": 200,
        ])
        files = try await listedFiles.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
        experiments = try await listedExperiments
        sessions = try await listedSessions
        if let selectedFile, files.contains(where: { $0.path == selectedFile && !$0.isDir }) {
            return
        }
        selectedFile = nil
        let remembered = UserDefaults.standard.string(forKey: Self.editorFileKey(project.id))
        if let remembered, files.contains(where: { $0.path == remembered && !$0.isDir }) {
            try await openFile(remembered)
        } else if let firstFile = files.first(where: { !$0.isDir }) {
            try await openFile(firstFile.path)
        }
    }

    func selectExperiment(_ id: String?) async {
        selectedExperimentId = id
        clearEditorBuffers()
        await runAction { try await self.refreshWorkspace() }
    }

    func openFile(_ path: String) async throws {
        guard let project else { return }
        if buffers[path] == nil {
            let file: FileContent = try await request("read_file", params: [
                "projectId": project.id,
                "experimentId": selectedExperimentId ?? NSNull(),
                "path": path,
            ])
            buffers[path] = file.content
            savedBuffers[path] = file.content
        }
        if !openOrder.contains(path) {
            openOrder.append(path)
        }
        selectedFile = path
        UserDefaults.standard.set(path, forKey: Self.editorFileKey(project.id))
    }

    func selectFile(_ path: String) {
        palette = nil
        centerTab = .editor
        revealLine = nil
        Task { await runAction { try await self.openFile(path) } }
    }

    func requestClose(_ path: String) {
        if dirtyFiles.contains(path) {
            closePrompt = path
        } else {
            closeFile(path)
        }
    }

    func confirmDiscardClose() {
        guard let path = closePrompt else { return }
        closePrompt = nil
        closeFile(path)
    }

    func closeFile(_ path: String) {
        buffers[path] = nil
        savedBuffers[path] = nil
        dirtyFiles.remove(path)
        openOrder.removeAll { $0 == path }
        if selectedFile == path {
            selectedFile = openOrder.last
            revealLine = nil
        }
    }

    func presentPalette(_ kind: PaletteKind) {
        palette = palette == kind ? nil : kind
    }

    func updateCursor(line: Int, column: Int) {
        if editorLine != line { editorLine = line }
        if editorColumn != column { editorColumn = column }
    }

    func flashStatus(_ message: String) {
        statusNote = message
        Task {
            try? await Task.sleep(nanoseconds: 2_200_000_000)
            if statusNote == message { statusNote = nil }
        }
    }

    func updateEditor(_ content: String) {
        guard let selectedFile else { return }
        buffers[selectedFile] = content
        if content == savedBuffers[selectedFile] {
            dirtyFiles.remove(selectedFile)
        } else {
            dirtyFiles.insert(selectedFile)
        }
    }

    func saveFile() async {
        guard let project, let selectedFile, let content = buffers[selectedFile] else { return }
        await runAction {
            let saved: FileContent = try await self.request("write_file", params: [
                "projectId": project.id,
                "experimentId": self.selectedExperimentId ?? NSNull(),
                "path": selectedFile,
                "content": content,
            ])
            self.buffers[selectedFile] = saved.content
            self.savedBuffers[selectedFile] = saved.content
            self.dirtyFiles.remove(selectedFile)
            self.flashStatus("Saved \(URL(fileURLWithPath: selectedFile).lastPathComponent)")
        }
    }

    func run() async {
        guard let project else { return }
        if !dirtyFiles.isEmpty, !(await saveAll()) {
            return
        }
        guard project.consentGranted else {
            showConsent = true
            return
        }
        await runAction {
            try await self.saveSettings()
            let request = RunRequest(
                projectId: project.id,
                experimentId: self.selectedExperimentId,
                baselineSessionId: nil,
                stdin: self.runStdin.isEmpty ? nil : self.runStdin
            )
            let session: Session = try await self.request("start_run", params: [
                "request": try self.jsonObject(request),
            ])
            self.activeSession = session
            self.output = ""
            self.stderr = ""
            self.runStats = nil
            self.centerTab = .editor
            try await self.refreshSessions()
        }
    }

    func runExperiment(_ experiment: Experiment) async {
        guard let project else { return }
        if !dirtyFiles.isEmpty, !(await saveAll()) {
            return
        }
        guard project.consentGranted else {
            showConsent = true
            return
        }
        await runAction {
            let request = RunRequest(
                projectId: project.id,
                experimentId: experiment.id,
                baselineSessionId: experiment.baselineSessionId,
                stdin: self.runStdin.isEmpty ? nil : self.runStdin
            )
            let session: Session = try await self.request("start_run", params: [
                "request": try self.jsonObject(request),
            ])
            self.activeSession = session
            self.output = ""
            self.stderr = ""
            self.selectedExperimentId = experiment.id
            self.clearEditorBuffers()
            self.centerTab = .editor
            try await self.refreshWorkspace()
        }
    }

    func cancelRun() async {
        guard let activeSession, activeSession.status == "running" else { return }
        await runAction {
            let _: String? = try await self.request("cancel_run", params: ["sessionId": activeSession.id])
        }
    }

    func grantConsentAndRun() async {
        guard let project else { return }
        await runAction {
            let updated: Project = try await self.request("set_project_consent", params: [
                "projectId": project.id,
                "granted": true,
            ])
            self.setProject(updated)
            self.showConsent = false
            await self.run()
        }
    }

    func selectSession(_ session: Session) async {
        activeSession = session
        if selectedExperimentId != session.experimentId {
            selectedExperimentId = session.experimentId
            clearEditorBuffers()
            await runAction { try await self.refreshWorkspace() }
        }
        selectedTraceId = nil
        selectedVariable = nil
        dataFlow = nil
        await runAction {
            let page: TracePage = try await self.request("list_trace_events", params: [
                "sessionId": session.id,
                "limit": 4000,
            ])
            self.traceEvents = page.events
            self.output = session.stdoutPreview
            self.stderr = session.stderrPreview
            let fullOutput: SessionOutput = try await self.request("get_session_output", params: [
                "sessionId": session.id,
            ])
            self.output = fullOutput.stdout
            self.stderr = fullOutput.stderr
            try await self.loadVariables(at: nil)
        }
    }

    func selectTrace(_ event: TraceEvent) async {
        selectedTraceId = event.id
        if let path = event.file {
            let relative = URL(fileURLWithPath: path).path
            let root = experiments.first(where: { $0.id == selectedExperimentId })?.path ?? project?.rootPath
            if let root, relative.hasPrefix(root + "/") {
                let file = String(relative.dropFirst(root.count + 1))
                do {
                    try await openFile(file)
                    centerTab = .editor
                    if let line = event.line, let value = Int(exactly: line), value > 0 {
                        revealLine = value
                        revealToken += 1
                    }
                } catch {
                    notice = error.localizedDescription
                }
            }
        }
        await runAction { try await self.loadVariables(at: event.seq) }
    }

    func selectVariable(_ name: String) async {
        selectedVariable = name
        guard let activeSession else { return }
        await runAction {
            async let history: [TraceEvent] = self.request("variable_history", params: [
                "sessionId": activeSession.id,
                "name": name,
                "limit": 300,
            ])
            async let flow: DataFlow = self.request("data_flow", params: [
                "sessionId": activeSession.id,
                "variable": name,
            ])
            self.variableHistory = try await history
            self.dataFlow = try await flow
        }
    }

    func createExperiment() async {
        guard let project, let baseline = sessions.first(where: { $0.kind == "baseline" && $0.status != "running" }) else {
            notice = "Run the project once before creating an experiment."
            return
        }
        let name = experimentName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        if !dirtyFiles.isEmpty, !(await saveAll()) {
            return
        }
        await runAction {
            let created: Experiment = try await self.request("create_experiment", params: [
                "projectId": project.id,
                "baselineSessionId": baseline.id,
                "name": name,
                "note": self.experimentNote.isEmpty ? NSNull() : self.experimentNote,
            ])
            self.experimentName = ""
            self.experimentNote = ""
            self.showNewExperiment = false
            self.notice = "Created experiment \(created.name)"
            try await self.refreshWorkspace()
            self.centerTab = .experiments
        }
    }

    func compare(_ baseline: Session, _ experiment: Session) async {
        await runAction {
            self.comparison = try await self.request("compare_sessions", params: [
                "baselineSessionId": baseline.id,
                "experimentSessionId": experiment.id,
            ])
            self.centerTab = .compare
        }
    }

    func saveSettings() async throws {
        guard let project else { return }
        let config = ProjectConfigInput(
            entryPoint: entryPoint.isEmpty ? nil : entryPoint,
            runArgs: splitArguments(runArguments),
            timeoutMs: UInt64(max(1, timeoutSeconds)) * 1000,
            tracing: tracingEnabled,
            pythonPath: pythonPath.isEmpty ? project.pythonPath : pythonPath
        )
        let updated: Project = try await request("update_project_config", params: [
            "projectId": project.id,
            "config": try jsonObject(config),
        ])
        setProject(updated)
    }

    func saveGlobalPythonPath() async {
        await runAction {
            let path: String? = self.pythonPath.isEmpty ? nil : self.pythonPath
            let _: String? = try await self.request("set_global_python_path", params: [
                "path": path ?? NSNull(),
            ])
            self.notice = "Python interpreter setting saved"
        }
    }

    private func saveAll() async -> Bool {
        let paths = Array(dirtyFiles)
        for path in paths {
            guard let project, let content = buffers[path] else { continue }
            do {
                let saved: FileContent = try await request("write_file", params: [
                    "projectId": project.id,
                    "experimentId": selectedExperimentId ?? NSNull(),
                    "path": path,
                    "content": content,
                ])
                savedBuffers[path] = saved.content
                dirtyFiles.remove(path)
            } catch {
                notice = error.localizedDescription
                return false
            }
        }
        return true
    }

    private func refreshSessions() async throws {
        guard let project else { return }
        sessions = try await request("list_sessions", params: [
            "projectId": project.id,
            "limit": 200,
        ])
        if let activeSession,
           let updated = sessions.first(where: { $0.id == activeSession.id }) {
            self.activeSession = updated
        }
    }

    private func loadVariables(at seq: Int64?) async throws {
        guard let activeSession else { return }
        variables = try await request("variables_at", params: [
            "sessionId": activeSession.id,
            "seq": seq.map { $0 as Any } ?? NSNull(),
        ])
    }

    private func receive(_ event: SidecarEvent) {
        switch event.name {
        case "run:output":
            guard let message = try? JSONDecoder().decode(RunOutputMessage.self, from: event.payload) else { return }
            if message.stream == "stdout" {
                output += message.chunk
            } else {
                stderr += message.chunk
            }
        case "run:trace":
            guard let message = try? JSONDecoder().decode(RunTraceMessage.self, from: event.payload) else { return }
            traceEvents.append(contentsOf: message.events)
        case "run:stats":
            if let values = try? JSONSerialization.jsonObject(with: event.payload) as? [String: Any],
               let elapsed = values["elapsedMs"] as? Int {
                runStats = String(format: "%.2fs", Double(elapsed) / 1000)
            }
        case "run:finished":
            if let finished = try? JSONDecoder().decode(Session.self, from: event.payload) {
                activeSession = finished
                if finished.status != "running" {
                    NotificationService.runFinished(
                        projectName: project?.name ?? "Project",
                        status: finished.status,
                        durationMs: finished.durationMs
                    )
                }
            }
            Task { await runAction { try await self.refreshSessions() } }
        case "workspace:changed":
            guard let changed = try? JSONDecoder().decode(WorkspaceChangedMessage.self, from: event.payload),
                  changed.workspaceId == project?.id || changed.workspaceId == selectedExperimentId else { return }
            Task { await runAction { try await self.refreshWorkspace() } }
        default:
            break
        }
    }

    private func setProject(_ project: Project) {
        if self.project?.id != project.id {
            clearEditorBuffers()
            selectedExperimentId = nil
            activeSession = nil
            traceEvents = []
            variables = []
            variableHistory = []
            dataFlow = nil
            comparison = nil
            output = ""
            stderr = ""
            HandoffService.begin(project: project)
            SpotlightIndexer.index(project: project)
        }
        self.project = project
        runArguments = project.runArgs.joined(separator: " ")
        entryPoint = project.entryPoint ?? ""
        timeoutSeconds = max(1, Int(project.timeoutMs / 1000))
        tracingEnabled = project.tracing
        pythonPath = project.pythonPath ?? ""
    }

    private func clearEditorBuffers() {
        selectedFile = nil
        buffers.removeAll()
        savedBuffers.removeAll()
        openOrder.removeAll()
        dirtyFiles.removeAll()
        revealLine = nil
        editorLine = 1
        editorColumn = 1
    }

    private static func editorFileKey(_ projectId: String) -> String {
        "editor.openFile.\(projectId)"
    }

    private func splitArguments(_ input: String) -> [String] {
        var result: [String] = []
        var current = ""
        var quote: Character?
        var escaping = false
        var started = false

        for character in input {
            if escaping {
                current.append(character)
                escaping = false
                started = true
            } else if character == "\\" && quote != "'" {
                escaping = true
                started = true
            } else if let activeQuote = quote {
                if character == activeQuote {
                    quote = nil
                } else {
                    current.append(character)
                }
            } else if character == "\"" || character == "'" {
                quote = character
                started = true
            } else if character.isWhitespace {
                if started {
                    result.append(current)
                    current = ""
                    started = false
                }
            } else {
                current.append(character)
                started = true
            }
        }
        if escaping { current.append("\\") }
        if started { result.append(current) }
        return result
    }

    private func request<Response: Decodable & Sendable>(
        _ method: String,
        params: sending [String: Any] = [:]
    ) async throws -> Response {
        try await client.request(method, params: params)
    }

    private func jsonObject<T: Encodable>(_ value: T) throws -> Any {
        let data = try JSONEncoder().encode(value)
        return try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
    }

    private func runAction(_ action: () async throws -> Void) async {
        isBusy = true
        defer { isBusy = false }
        do {
            try await action()
        } catch let error as SidecarError {
            if case .response(let message) = error, message.localizedCaseInsensitiveContains("consent") {
                showConsent = true
            } else {
                notice = error.localizedDescription
            }
        } catch {
            notice = error.localizedDescription
        }
    }

    deinit {
        eventTask?.cancel()
        client.stop()
    }
}

private struct SessionOutput: Decodable, Sendable {
    let stdout: String
    let stderr: String
}
