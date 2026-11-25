import SwiftUI

private enum CanvasPalette {
    static let panel = GlassTheme.panel
    static let raised = GlassTheme.raised
    static let border = GlassTheme.border
    static let accent = GlassTheme.accent
    static let muted = GlassTheme.muted
    static let warning = GlassTheme.warning
}

struct CanvasView: View {
    @EnvironmentObject private var model: AppModel
    private let columns = [GridItem(.adaptive(minimum: 220), spacing: 12)]

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Product notes")
                        .font(.system(size: 15, weight: .semibold))
                    Text("Optional notes about the product. This page is separate from the code trace.")
                        .font(.system(size: 12))
                        .foregroundStyle(CanvasPalette.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Menu {
                    ForEach(ContextNodeKind.allCases) { kind in
                        Button {
                            Task { await model.addCanvasNode(kind) }
                        } label: {
                            Label {
                                Text(kind.title)
                            } icon: {
                                AppIcon(kind.symbol, size: 14)
                            }
                        }
                    }
                } label: {
                    IconLabel("Add context", icon: "plus")
                }
                .buttonStyle(.borderedProminent)
                .help("Add a note for one part of the product")
                .accessibilityLabel("Add context")
            }
            .padding(14)

            Divider().overlay(CanvasPalette.border)

            if model.canvasLoading && model.canvasNodes.isEmpty {
                VStack(spacing: 10) {
                    ProgressView("Loading product notes…")
                    Text("These notes are stored on this Mac.")
                        .font(.system(size: 12))
                        .foregroundStyle(CanvasPalette.muted)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let error = model.canvasLoadError, model.canvasNodes.isEmpty {
                ContentUnavailableView {
                    Label {
                        Text("Product notes could not load")
                    } icon: {
                        AppIcon("alert", size: 44)
                    }
                } description: {
                    Text(error)
                } actions: {
                    Button("Try again") { Task { await model.loadCanvas() } }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if model.canvasNodes.isEmpty {
                ContentUnavailableView {
                    Label {
                        Text("No product notes yet")
                    } icon: {
                        AppIcon("grid", size: 44)
                    }
                } description: {
                    Text("Add a note for part of the product, such as the interface or the database. This is separate from the code trace.")
                } actions: {
                    Text("Use Add context above to create the first note.")
                        .font(.system(size: 12))
                        .foregroundStyle(CanvasPalette.muted)
                }
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
                    AppIcon(node.kind.symbol, size: 16)
                        .foregroundStyle(CanvasPalette.accent)
                    Text(node.kind.title.uppercased())
                        .font(.system(size: 9, weight: .bold))
                        .tracking(1)
                        .foregroundStyle(CanvasPalette.muted)
                    Spacer()
                    if node.status == .needsReview {
                        AppIcon("alert", size: 13)
                            .foregroundStyle(CanvasPalette.warning)
                            .phaseAnimator([false, true]) { content, pulse in
                                content.opacity(pulse ? 0.55 : 1)
                            } animation: { _ in
                                .easeInOut(duration: 1.1)
                            }
                            .help("An upstream context change needs review")
                    }
                }
                Text(node.title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.primary)
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
            Text("Connections")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(CanvasPalette.muted)
            Text("What else may need a look if one note changes.")
                .font(.system(size: 11))
                .foregroundStyle(CanvasPalette.muted)
            if dependencies.isEmpty {
                Text("Connect notes to see what may be affected by a change.")
                    .font(.system(size: 12))
                    .foregroundStyle(CanvasPalette.muted)
            } else {
                ForEach(dependencies) { dependency in
                    let source = nodes.first { $0.id == dependency.sourceId }
                    let target = nodes.first { $0.id == dependency.targetId }
                    HStack(spacing: 8) {
                        Text(source?.title ?? "Unknown")
                        AppIcon("arrow-right", size: 12)
                            .foregroundStyle(CanvasPalette.accent)
                        Text(target?.title ?? "Unknown")
                        Spacer()
                        if target?.status == .needsReview {
                            Text("Review")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(CanvasPalette.warning)
                        }
                    }
                    .font(.system(size: 12, design: .monospaced))
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
                AppIcon(node.kind.symbol, size: 16).foregroundStyle(CanvasPalette.accent)
                Text("Note")
                    .font(.system(size: 12, weight: .semibold))
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
            Text("Affects")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(CanvasPalette.muted)
            Text("What else should be reviewed if this changes.")
                .font(.system(size: 11))
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
                    AppIcon("arrow-right", size: 11).foregroundStyle(CanvasPalette.accent)
                    Text(nodes.first { $0.id == dependency.targetId }?.title ?? "Unknown")
                        .font(.system(size: 10))
                    Spacer()
                    Button {
                        Task { await model.removeCanvasDependency(dependency) }
                    } label: {
                        AppIcon("close", size: 10)
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
