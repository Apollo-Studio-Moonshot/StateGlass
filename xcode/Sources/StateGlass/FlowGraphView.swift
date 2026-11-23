import SwiftUI

struct FlowGraphView: View {
    let flow: DataFlow

    private var layout: FlowGraphLayout {
        FlowGraphLayout(flow: flow)
    }

    var body: some View {
        let graph = layout
        ScrollView([.horizontal, .vertical]) {
            Canvas(opaque: false, colorMode: .linear) { context, _ in
                drawEdges(graph.edges, positions: graph.positions, in: &context)
                drawNodes(graph.nodes, in: &context)
            }
            .frame(width: graph.size.width, height: graph.size.height)
            .drawingGroup()
            .accessibilityLabel("Data flow graph with \(flow.nodes.count) nodes and \(flow.edges.count) connections")
        }
        .scrollIndicators(.automatic)
    }

    private func drawEdges(
        _ edges: [FlowEdge],
        positions: [String: CGRect],
        in context: inout GraphicsContext
    ) {
        for edge in edges {
            guard let source = positions[edge.source], let target = positions[edge.target] else {
                continue
            }
            var path = Path()
            let color: Color = edge.kind == "update" ? .cyan.opacity(0.82) : Color(nsColor: .tertiaryLabelColor)
            let start: CGPoint
            let end: CGPoint
            if edge.kind == "read" {
                start = CGPoint(x: source.midX, y: source.maxY)
                end = CGPoint(x: target.midX, y: target.minY)
                let controlOffset = max(24, (end.y - start.y) * 0.45)
                path.move(to: start)
                path.addCurve(
                    to: end,
                    control1: CGPoint(x: start.x, y: start.y + controlOffset),
                    control2: CGPoint(x: end.x, y: end.y - controlOffset)
                )
            } else {
                start = CGPoint(x: source.maxX, y: source.midY)
                end = CGPoint(x: target.minX, y: target.midY)
                let controlOffset = max(24, (end.x - start.x) * 0.45)
                path.move(to: start)
                path.addCurve(
                    to: end,
                    control1: CGPoint(x: start.x + controlOffset, y: start.y),
                    control2: CGPoint(x: end.x - controlOffset, y: end.y)
                )
            }
            context.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: 1.5))
            drawArrow(at: end, color: color, vertical: edge.kind == "read", in: &context)
        }
    }

    private func drawNodes(_ nodes: [PositionedFlowNode], in context: inout GraphicsContext) {
        for positioned in nodes {
            let node = positioned.node
            let rect = positioned.rect
            let tint: Color = node.role == "target" ? .cyan : Color(nsColor: .secondaryLabelColor)
            let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)

            context.fill(shape.path(in: rect), with: .color(Color(nsColor: .controlBackgroundColor)))
            context.stroke(shape.path(in: rect), with: .color(tint.opacity(0.45)), lineWidth: 1)

            drawText(
                Text(node.label)
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundColor(Color(nsColor: .labelColor)),
                at: CGPoint(x: rect.minX + 10, y: rect.minY + 18),
                in: rect,
                context: &context
            )
            drawText(
                Text(node.role.uppercased())
                    .font(.system(size: 8, weight: .bold))
                    .foregroundColor(tint),
                at: CGPoint(x: rect.minX + 10, y: rect.minY + 34),
                in: rect,
                context: &context
            )
            drawText(
                Text(node.value)
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundColor(Color(nsColor: .secondaryLabelColor)),
                at: CGPoint(x: rect.minX + 10, y: rect.minY + 55),
                in: rect,
                context: &context
            )
            drawText(
                Text("\(node.file.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "unknown"):\(node.line ?? 0) · #\(node.seq)")
                    .font(.system(size: 8, design: .monospaced))
                    .foregroundColor(Color(nsColor: .tertiaryLabelColor)),
                at: CGPoint(x: rect.minX + 10, y: rect.minY + 76),
                in: rect,
                context: &context
            )
        }
    }

    private func drawText(
        _ text: Text,
        at point: CGPoint,
        in rect: CGRect,
        context: inout GraphicsContext
    ) {
        var clippedContext = context
        clippedContext.clip(to: Path(rect))
        clippedContext.draw(clippedContext.resolve(text), at: point, anchor: .leading)
    }

    private func drawArrow(
        at point: CGPoint,
        color: Color,
        vertical: Bool,
        in context: inout GraphicsContext
    ) {
        var path = Path()
        path.move(to: point)
        if vertical {
            path.addLine(to: CGPoint(x: point.x - 4, y: point.y - 6))
            path.addLine(to: CGPoint(x: point.x + 4, y: point.y - 6))
        } else {
            path.addLine(to: CGPoint(x: point.x - 6, y: point.y - 4))
            path.addLine(to: CGPoint(x: point.x - 6, y: point.y + 4))
        }
        path.closeSubpath()
        context.fill(path, with: .color(color))
    }
}

private struct PositionedFlowNode {
    let node: FlowNode
    let rect: CGRect
}

private struct FlowGraphLayout {
    let nodes: [PositionedFlowNode]
    let edges: [FlowEdge]
    let positions: [String: CGRect]
    let size: CGSize

    init(flow: DataFlow) {
        let nodeWidth: CGFloat = 210
        let nodeHeight: CGFloat = 90
        let columnGap: CGFloat = 76
        let rowGap: CGFloat = 24
        let margin: CGFloat = 28
        let columnWidth = nodeWidth + columnGap
        let lastColumn = flow.nodes.filter { $0.role == "target" }.map(\.step).max() ?? 0
        let inputNodes = flow.nodes.filter { $0.role != "target" }
        let inputColumns = max(1, min(12, inputNodes.count))
        let inputRows = (inputNodes.count + inputColumns - 1) / inputColumns
        var positioned: [PositionedFlowNode] = []
        var positions: [String: CGRect] = [:]
        var inputIndex = 0
        let targetY = margin + CGFloat(inputRows) * (nodeHeight + rowGap) + 72

        for node in flow.nodes {
            let x: CGFloat
            let y: CGFloat
            if node.role == "target" {
                x = margin + CGFloat(node.step) * columnWidth
                y = targetY
            } else {
                x = margin + CGFloat(inputIndex % inputColumns) * columnWidth
                y = margin + CGFloat(inputIndex / inputColumns) * (nodeHeight + rowGap)
                inputIndex += 1
            }
            let rect = CGRect(x: x, y: y, width: nodeWidth, height: nodeHeight)
            positioned.append(PositionedFlowNode(node: node, rect: rect))
            positions[node.id] = rect
        }

        let targetColumnCount = Int(lastColumn) + 1
        let graphColumnCount = max(targetColumnCount, inputColumns)
        let contentWidth = margin * 2 + CGFloat(graphColumnCount) * columnWidth
        let contentHeight = positioned.map(\.rect.maxY).max().map { $0 + margin } ?? 280
        self.nodes = positioned
        self.edges = flow.edges
        self.positions = positions
        self.size = CGSize(width: max(contentWidth, 280), height: max(contentHeight, 280))
    }
}
