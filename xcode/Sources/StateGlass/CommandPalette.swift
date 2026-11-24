import SwiftUI

enum PaletteKind: String, Identifiable {
    case files
    case commands
    var id: String { rawValue }
}

/// Floating keyboard palette. ⌘P jumps to a file. ⌘⇧P runs a command.
struct CommandPalette: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.openSettings) private var openSettings
    let kind: PaletteKind

    @State private var query = ""
    @State private var selection = 0
    @FocusState private var focused: Bool

    var body: some View {
        ZStack(alignment: .top) {
            Color.black.opacity(0.22)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture { model.palette = nil }

            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    AppIcon(kind == .files ? "file" : "sliders", size: 14)
                        .foregroundStyle(.secondary)
                    TextField(kind == .files ? "Go to file" : "Type a command", text: $query)
                        .textFieldStyle(.plain)
                        .font(.system(size: 14))
                        .focused($focused)
                        .onSubmit(activateSelection)
                        .onKeyPress(.downArrow) {
                            move(1)
                            return .handled
                        }
                        .onKeyPress(.upArrow) {
                            move(-1)
                            return .handled
                        }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 11)

                Divider()

                if rows.isEmpty {
                    Text("No matches")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 72)
                } else {
                    ScrollViewReader { proxy in
                        ScrollView {
                            LazyVStack(spacing: 1) {
                                ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                                    rowButton(row, index: index)
                                        .id(index)
                                }
                            }
                            .padding(6)
                        }
                        .frame(maxHeight: 320)
                        .onChange(of: selection) { _, index in
                            proxy.scrollTo(index, anchor: .center)
                        }
                    }
                }

                Divider()
                HStack {
                    Text(kind == .files ? "Files" : "Commands")
                    Spacer()
                    Text("↑↓  ·  return  ·  esc")
                }
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
            }
            .frame(width: 560)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(Color(nsColor: .separatorColor))
            }
            .shadow(color: .black.opacity(0.22), radius: 28, y: 14)
            .padding(.top, 58)
            .onExitCommand { model.palette = nil }
        }
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isModal)
        .accessibilityLabel(kind == .files ? "Go to file" : "Command palette")
        .onAppear { focused = true }
        .onChange(of: query) { _, _ in selection = 0 }
        .onChange(of: rows.count) { _, count in
            if selection >= count { selection = max(0, count - 1) }
        }
    }

    private var rows: [PaletteRow] {
        switch kind {
        case .files: fileRows
        case .commands: commandRows
        }
    }

    private var fileRows: [PaletteRow] {
        let files = model.files.filter { !$0.isDir }
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            let open = model.openFilePaths.compactMap { path in files.first { $0.path == path } }
            let openPaths = Set(open.map(\.path))
            let rest = files.filter { !openPaths.contains($0.path) }
            return (open + rest).prefix(40).map(fileRow)
        }
        return files.compactMap { file -> (PaletteRow, Int)? in
            let name = Fuzzy.score(trimmed, file.name).map { $0 + 40 }
            let path = Fuzzy.score(trimmed, file.path)
            guard let score = [name, path].compactMap({ $0 }).max() else { return nil }
            return (fileRow(file), score)
        }
        .sorted { $0.1 > $1.1 }
        .prefix(40)
        .map(\.0)
    }

    private var commandRows: [PaletteRow] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let available = commands
        if trimmed.isEmpty { return available }
        return available.compactMap { row -> (PaletteRow, Int)? in
            guard let score = Fuzzy.score(trimmed, row.title) else { return nil }
            return (row, score)
        }
        .sorted { $0.1 > $1.1 }
        .map(\.0)
    }

    private var commands: [PaletteRow] {
        var rows: [PaletteRow] = []
        if model.project != nil {
            rows.append(PaletteRow(id: "goto", title: "Go to File…", shortcut: "⌘P") {
                model.palette = .files
            })
        }
        rows.append(command("open", "Open Project…", "⌘O") { model.openProjectPanel() })
        rows.append(command("sample", "Load Sample Project", "") { Task { await model.loadSample() } })
        if model.selectedFile != nil {
            rows.append(command("save", "Save File", "⌘S") { Task { await model.saveFile() } })
            rows.append(command("close", "Close Editor", "⌘W") {
                if let path = model.selectedFile { model.requestClose(path) }
            })
        }
        if model.project != nil && !model.isRunning {
            rows.append(command("run", "Run Project", "⌘↩") { Task { await model.run() } })
        }
        if model.isRunning {
            rows.append(command("cancel", "Cancel Run", "⌘.") { Task { await model.cancelRun() } })
        }
        if model.project != nil {
            rows.append(command("experiment", "New Experiment…", "⌘⇧E") { model.showNewExperiment = true })
            rows.append(command("canvas", "Show Canvas", "⌘0") { model.centerTab = .canvas })
            rows.append(command("editor", "Show Editor", "⌘1") { model.centerTab = .editor })
            rows.append(command("flow", "Show Data Flow", "⌘2") { model.centerTab = .flow })
            rows.append(command("compare", "Show Compare", "⌘3") { model.centerTab = .compare })
            rows.append(command("experiments", "Show Experiments", "⌘4") { model.centerTab = .experiments })
            rows.append(command("inspector", model.showInspector ? "Hide Inspector" : "Show Inspector", "⌘⌥I") {
                model.showInspector.toggle()
            })
        }
        rows.append(command("settings", "Settings…", "⌘,") { openSettings() })
        for project in model.projects where project.id != model.project?.id {
            rows.append(command("recent-\(project.id)", "Open \(project.name)", "") {
                Task { await model.openRecentProject(project) }
            })
        }
        return rows
    }

    private func fileRow(_ file: FileEntry) -> PaletteRow {
        PaletteRow(
            id: file.path,
            title: file.name,
            detail: (file.path as NSString).deletingLastPathComponent,
            shortcut: ""
        ) {
            model.selectFile(file.path)
        }
    }

    private func command(_ id: String, _ title: String, _ shortcut: String, action: @escaping () -> Void) -> PaletteRow {
        PaletteRow(id: id, title: title, shortcut: shortcut) {
            model.palette = nil
            action()
        }
    }

    private func rowButton(_ row: PaletteRow, index: Int) -> some View {
        let selected = index == selection
        return Button {
            selection = index
            row.action()
        } label: {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(row.title)
                        .lineLimit(1)
                    if !row.detail.isEmpty {
                        Text(row.detail)
                            .font(.system(size: 11))
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .foregroundStyle(selected ? Color(nsColor: .alternateSelectedControlTextColor).opacity(0.8) : .secondary)
                    }
                }
                Spacer(minLength: 12)
                if !row.shortcut.isEmpty {
                    Text(row.shortcut)
                        .font(.system(size: 11))
                        .foregroundStyle(selected ? Color(nsColor: .alternateSelectedControlTextColor).opacity(0.8) : .secondary)
                }
            }
            .font(.system(size: 13))
            .foregroundStyle(selected ? Color(nsColor: .alternateSelectedControlTextColor) : .primary)
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                if selected {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color(nsColor: .selectedContentBackgroundColor))
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            if hovering { selection = index }
        }
        .accessibilityLabel(row.title)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func move(_ delta: Int) {
        guard !rows.isEmpty else { return }
        selection = min(max(0, selection + delta), rows.count - 1)
    }

    private func activateSelection() {
        guard rows.indices.contains(selection) else { return }
        rows[selection].action()
    }
}

private struct PaletteRow: Identifiable {
    let id: String
    let title: String
    var detail: String = ""
    let shortcut: String
    let action: () -> Void
}

enum Fuzzy {
    static func score(_ query: String, _ candidate: String) -> Int? {
        let parts = query.split(whereSeparator: \.isWhitespace).map(String.init)
        if parts.isEmpty { return 1 }
        var total = 0
        for part in parts {
            guard let partScore = scorePart(part, candidate) else { return nil }
            total += partScore
        }
        return total
    }

    private static func scorePart(_ query: String, _ candidate: String) -> Int? {
        let queryChars = Array(query.lowercased())
        if queryChars.isEmpty { return 1 }
        let candidateChars = Array(candidate.lowercased())
        var queryIndex = 0
        var score = 0
        var streak = 0
        for (index, character) in candidateChars.enumerated() {
            if queryIndex < queryChars.count && character == queryChars[queryIndex] {
                queryIndex += 1
                streak += 1
                score += 6 + streak * 4
                if index == 0 || "/._- ".contains(candidateChars[index - 1]) {
                    score += 8
                }
            } else {
                streak = 0
            }
        }
        guard queryIndex == queryChars.count else { return nil }
        return score - candidateChars.count / 10
    }
}
