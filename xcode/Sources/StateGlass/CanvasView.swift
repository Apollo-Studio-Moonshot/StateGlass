import SwiftUI

private enum CanvasPalette {
    static let panel = Color(red: 0.075, green: 0.09, blue: 0.12)
    static let raised = Color(red: 0.105, green: 0.125, blue: 0.16)
    static let border = Color.white.opacity(0.09)
    static let accent = Color(red: 0.39, green: 0.75, blue: 0.95)
    static let muted = Color(red: 0.55, green: 0.61, blue: 0.69)
    static let warning = Color(red: 1, green: 0.68, blue: 0.31)
}

struct CanvasView: View {
    @EnvironmentObject private var model: AppModel
    private let columns = [GridItem(.adaptive(minimum: 220), spacing: 12)]

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("WEAR ALL HATS")
                        .font(.system(size: 10, weight: .bold))
                        .tracking(1.3)
                        .foregroundStyle(CanvasPalette.muted)
                    Text("One workspace for the whole product")
                        .font(.system(size: 15, weight: .semibold))
                }
                Spacer()
                Menu {
                    ForEach(ContextNodeKind.allCases) { kind in
                        Button {
                            Task { await model.addCanvasNode(kind) }
                        } label: {
                            Label(kind.title, systemImage: kind.symbol)
                        }
                    }
                } label: {
                    Label("Add context", systemImage: "plus")
                }
                .buttonStyle(.borderedProminent)
            }
            .padding(14)

            Divider().overlay(CanvasPalette.border)

            if model.canvasNodes.isEmpty {
                ContentUnavailableView(
                    "Loading your canvas",
                    systemImage: "square.grid.2x2",
                    description: Text("Your product context is stored locally.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                HSplitView {
                    ScrollView {
                        LazyVGrid(columns: columns, alignment: .leading, spacing: 12) {
                            ForEach(model.canvasNodes) { node in
                                ContextNodeCard(
                                    node: node,
                                    isFocused: model.focusedNodeID == node.id,
                                    dependencies: relatedDependencies(for: node)
                                ) {
                                    model.focusCanvasNode(node)
                                }
                            }
                        }
                        .padding(16)
                        .frame(maxWidth: .infinity, alignment: .leading)

                        DependencyMap(
                            nodes: model.canvasNodes,
                            dependencies: model.canvasDependencies
                        )
                        .padding(.horizontal, 16)
                        .padding(.bottom, 16)
                    }
                    .frame(minWidth: 420)

                    if let node = model.focusedCanvasNode {
                        ContextNodeInspector(
                            node: node,
                            nodes: model.canvasNodes,
                            dependencies: model.canvasDependencies
                        )
                        .frame(minWidth: 240, idealWidth: 285, maxWidth: 340)
                    }
                }
            }
        }
        .background(CanvasPalette.panel)
        .task { await model.loadCanvasIfNeeded() }
    }

    private func relatedDependencies(for node: ContextNode) -> [NodeDependency] {
        model.canvasDependencies.filter {
            $0.sourceId == node.id || $0.targetId == node.id
        }
    }
}

private struct ContextNodeCard: View {
    let node: ContextNode
    let isFocused: Bool
    let dependencies: [NodeDependency]
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Image(systemName: node.kind.symbol)
                        .foregroundStyle(CanvasPalette.accent)
                    Text(node.kind.title.uppercased())
                        .font(.system(size: 9, weight: .bold))
                        .tracking(1)
                        .foregroundStyle(CanvasPalette.muted)
                    Spacer()
                    if node.status == .needsReview {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(CanvasPalette.warning)
                            .symbolEffect(.pulse)
                            .help("An upstream context change needs review")
                    }
                }
                Text(node.title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text(node.summary.isEmpty ? "Add context for this part of your product." : node.summary)
                    .font(.system(size: 11))
                    .foregroundStyle(CanvasPalette.muted)
                    .multilineTextAlignment(.leading)
                    .lineLimit(3)
                    .frame(maxWidth: .infinity, minHeight: 34, alignment: .topLeading)
                HStack {
                    Text(node.status.title)
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(node.status == .needsReview ? CanvasPalette.warning : CanvasPalette.muted)
                    Spacer()
                    Text("\(dependencies.count) connections")
                        .font(.system(size: 9))
                        .foregroundStyle(CanvasPalette.muted)
                }
            }
            .padding(13)
            .background(CanvasPalette.raised, in: RoundedRectangle(cornerRadius: 10))
            .overlay {
                RoundedRectangle(cornerRadius: 10)
                    .stroke(isFocused ? CanvasPalette.accent.opacity(0.8) : CanvasPalette.border, lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(node.kind.title) node: \(node.title), \(node.status.title)")
    }
}

private struct DependencyMap: View {
    let nodes: [ContextNode]
    let dependencies: [NodeDependency]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("DEPENDENCY MAP")
                .font(.system(size: 9, weight: .bold))
                .tracking(1.1)
                .foregroundStyle(CanvasPalette.muted)
            if dependencies.isEmpty {
                Text("Connect context nodes to see what may be affected by a change.")
                    .font(.system(size: 10))
                    .foregroundStyle(CanvasPalette.muted)
            } else {
                ForEach(dependencies) { dependency in
                    let source = nodes.first { $0.id == dependency.sourceId }
                    let target = nodes.first { $0.id == dependency.targetId }
                    HStack(spacing: 8) {
                        Text(source?.title ?? "Unknown")
                        Image(systemName: "arrow.right")
                            .foregroundStyle(CanvasPalette.accent)
                        Text(target?.title ?? "Unknown")
                        Spacer()
                        if target?.status == .needsReview {
                            Text("REVIEW")
                                .font(.system(size: 8, weight: .bold))
                                .foregroundStyle(CanvasPalette.warning)
                        }
                    }
                    .font(.system(size: 10, design: .monospaced))
                    .padding(9)
                    .background(CanvasPalette.raised, in: RoundedRectangle(cornerRadius: 6))
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(CanvasPalette.panel, in: RoundedRectangle(cornerRadius: 9))
        .overlay(RoundedRectangle(cornerRadius: 9).stroke(CanvasPalette.border, lineWidth: 1))
    }
}

private struct ContextNodeInspector: View {
    @EnvironmentObject private var model: AppModel
    let node: ContextNode
    let nodes: [ContextNode]
    let dependencies: [NodeDependency]
    @State private var title = ""
    @State private var summary = ""

    private var outgoingDependencies: [NodeDependency] {
        dependencies.filter { $0.sourceId == node.id }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: node.kind.symbol).foregroundStyle(CanvasPalette.accent)
                Text("CONTEXT")
                    .font(.system(size: 9, weight: .bold))
                    .tracking(1)
                    .foregroundStyle(CanvasPalette.muted)
                Spacer()
                Text(node.status.title)
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(node.status == .needsReview ? CanvasPalette.warning : CanvasPalette.muted)
            }
            TextField("Title", text: $title)
                .textFieldStyle(.roundedBorder)
            TextField("What should you remember?", text: $summary, axis: .vertical)
                .lineLimit(3...7)
                .textFieldStyle(.roundedBorder)
            Button("Save context") {
                var updated = node
                updated.title = title
                updated.summary = summary
                Task { await model.updateCanvasNode(updated) }
            }
            .buttonStyle(.borderedProminent)
            .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            if node.status == .needsReview {
                Button("Mark reviewed") {
                    var updated = node
                    updated.status = .active
                    Task { await model.updateCanvasNode(updated) }
                }
                .buttonStyle(.bordered)
            }

            Divider().overlay(CanvasPalette.border)
            Text("AFFECTS")
                .font(.system(size: 9, weight: .bold))
                .tracking(1)
                .foregroundStyle(CanvasPalette.muted)
            Menu("Add dependency") {
                ForEach(nodes.filter { candidate in
                    candidate.id != node.id &&
                        !outgoingDependencies.contains(where: { $0.targetId == candidate.id })
                }) { target in
                    Button(target.title) {
                        Task { await model.addCanvasDependency(from: node.id, to: target.id) }
                    }
                }
            }
            .disabled(nodes.count < 2)

            ForEach(outgoingDependencies) { dependency in
                HStack(spacing: 6) {
                    Image(systemName: "arrow.right").foregroundStyle(CanvasPalette.accent)
                    Text(nodes.first { $0.id == dependency.targetId }?.title ?? "Unknown")
                        .font(.system(size: 10))
                    Spacer()
                    Button {
                        Task { await model.removeCanvasDependency(dependency) }
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 9, weight: .bold))
                    }
                    .buttonStyle(.plain)
                    .help("Remove dependency")
                }
            }
            Spacer()
        }
        .padding(14)
        .background(CanvasPalette.panel)
        .onAppear(perform: syncDraft)
        .onChange(of: node.id) { _, _ in syncDraft() }
        .onChange(of: node.title) { _, _ in syncDraft() }
        .onChange(of: node.summary) { _, _ in syncDraft() }
    }

    private func syncDraft() {
        title = node.title
        summary = node.summary
    }
}
