import { useMemo } from "react";
import {
  Background,
  BackgroundVariant,
  Controls,
  Handle,
  MarkerType,
  Position,
  ReactFlow,
  type Edge,
  type Node,
  type NodeProps,
} from "@xyflow/react";
import { useStore } from "../store";
import type { FlowNode } from "../types";
import { clip, isNoisyType } from "../lib/format";
import { Badge, DropdownSelect, EmptyState, IconButton, Spinner } from "./ui";
import { AlertIcon, ArrowRightIcon, FlowIcon, RefreshIcon, VariableIcon } from "./Icons";

type FlowNodeData = Record<string, unknown> & { item: FlowNode };
type AppFlowNode = Node<FlowNodeData, "variableNode">;

export function DataFlowPanel() {
  const session = useStore((state) => state.activeSession);
  const workspace = useStore((state) => state.workspace);
  const selectedVariable = useStore((state) => state.selectedVariable);
  const variables = useStore((state) => state.variables);
  const dataFlow = useStore((state) => state.dataFlow);
  const loading = useStore((state) => state.flowLoading);
  const loadFlow = useStore((state) => state.loadFlow);
  const selectVariable = useStore((state) => state.selectVariable);
  const revealLocation = useStore((state) => state.revealLocation);

  const options = useMemo(
    () =>
      variables
        .filter((variable) => !isNoisyType(variable.vtype) && variable.name !== "self")
        .slice(0, 80)
        .map((variable) => ({
          value: variable.name,
          label: variable.name,
          description: `${variable.vtype} · ${clip(variable.value, 40)}`,
        })),
    [variables],
  );

  const { nodes, edges } = useMemo(() => {
    if (!dataFlow) return { nodes: [] as AppFlowNode[], edges: [] as Edge[] };
    const targets = dataFlow.nodes
      .filter((node) => node.role === "target")
      .sort((left, right) => left.seq - right.seq);
    const inputCounts = new Map<number, number>();
    const rfNodes: AppFlowNode[] = [];
    for (const item of dataFlow.nodes) {
      if (item.role === "target") {
        const index = targets.findIndex((target) => target.id === item.id);
        rfNodes.push({
          id: item.id,
          type: "variableNode",
          position: { x: Math.max(0, index) * 380, y: 300 },
          data: { item },
        });
      }
    }
    for (const item of dataFlow.nodes) {
      if (item.role !== "input") continue;
      const count = inputCounts.get(item.step) ?? 0;
      inputCounts.set(item.step, count + 1);
      rfNodes.push({
        id: item.id,
        type: "variableNode",
        position: {
          x: Math.max(0, item.step + 1) * 380 - 270,
          y: 40 + count * 92,
        },
        data: { item },
      });
    }
    const rfEdges: Edge[] = dataFlow.edges.map((edge) => ({
      id: edge.id,
      source: edge.source,
      target: edge.target,
      label: edge.label,
      type: edge.kind === "read" ? "smoothstep" : "default",
      animated: false,
      style: {
        stroke: edge.kind === "read" ? "var(--flow-read, #7f8da3)" : "var(--accent, #5b93ff)",
        strokeWidth: 1.4,
        strokeDasharray: edge.kind === "read" ? "5 4" : undefined,
      },
      labelStyle: { fill: "var(--text-muted, #8b95a7)", fontSize: 10 },
      labelBgStyle: { fill: "var(--bg, #0a0c10)", fillOpacity: 0.9 },
      labelBgPadding: [4, 2],
      labelBgBorderRadius: 3,
      markerEnd: { type: MarkerType.ArrowClosed, width: 14, height: 14, color: "var(--text-faint, #5d6675)" },
    }));
    return { nodes: rfNodes, edges: rfEdges };
  }, [dataFlow]);

  if (!session) {
    return (
      <div className="flow-panel">
        <EmptyState
          icon={<FlowIcon size={26} />}
          title="No execution to analyze"
          description="Run the project with tracing, then select a variable to see how its value was produced."
        />
      </div>
    );
  }

  const root = workspace?.root ?? session.cwd;

  return (
    <div className="flow-panel">
      <div className="flow-toolbar">
        <div className="flow-toolbar-title">
          <FlowIcon size={15} />
          <span>Data flow</span>
          {selectedVariable && <Badge tone="accent">{selectedVariable}</Badge>}
        </div>
        <DropdownSelect
          value={selectedVariable}
          options={options}
          onChange={(value) => void selectVariable(value)}
          placeholder="Select a variable…"
          width={320}
          align="left"
          className="flow-variable-select"
        />
        <span className="muted small">
          {dataFlow ? `${dataFlow.nodes.length} nodes · ${dataFlow.edges.length} edges` : ""}
        </span>
        <div className="flow-toolbar-spacer" />
        <IconButton title="Rebuild data flow" onClick={() => void loadFlow()} disabled={!selectedVariable}>
          <RefreshIcon size={14} />
        </IconButton>
      </div>

      {!selectedVariable ? (
        <div className="flow-suggestions">
          <EmptyState
            icon={<VariableIcon size={24} />}
            title="Choose a variable"
            description="Pick a variable from the inspector or from the list below to build its data-flow graph."
          />
          {options.length > 0 && (
            <div className="suggestion-grid">
              {options.slice(0, 18).map((option) => (
                <button
                  type="button"
                  key={option.value}
                  className="suggestion"
                  onClick={() => void selectVariable(option.value)}
                >
                  <span className="suggestion-name">{option.label}</span>
                  <span className="suggestion-value">{option.description}</span>
                </button>
              ))}
            </div>
          )}
        </div>
      ) : (
        <>
          {loading && (
            <div className="flow-loading">
              <Spinner size={16} /> Building graph…
            </div>
          )}
          {dataFlow && dataFlow.nodes.length === 0 && (
            <EmptyState
              icon={<FlowIcon size={24} />}
              title="No changes recorded"
              description={dataFlow.note}
            />
          )}
          {dataFlow && dataFlow.nodes.length > 0 && (
            <div className="flow-canvas">
              <ReactFlow
                nodes={nodes}
                edges={edges}
                nodeTypes={nodeTypes}
                fitView
                fitViewOptions={{ padding: 0.22, maxZoom: 1 }}
                minZoom={0.15}
                maxZoom={1.6}
                nodesConnectable={false}
                onNodeClick={(_, node) => {
                  const item = (node.data as FlowNodeData).item;
                  void revealLocation(item.file, item.line);
                }}
                proOptions={{ hideAttribution: false }}
              >
                <Background variant={BackgroundVariant.Dots} gap={22} size={1} color="#1a212b" />
                <Controls showInteractive={false} position="bottom-left" />
              </ReactFlow>
            </div>
          )}
          {dataFlow && (
            <div className="flow-footer">
              <div className="flow-note">
                <AlertIcon size={12} />
                <span>{dataFlow.note}</span>
              </div>
              <div className="flow-sites">
                <div className="flow-sites-head">
                  <span>Assignment site</span>
                  <span>Function</span>
                  <span>Reads</span>
                  <span>Callee</span>
                  <span>Match</span>
                </div>
                {dataFlow.assignmentSites.length === 0 && (
                  <div className="flow-sites-empty">No assignment metadata for this variable.</div>
                )}
                {dataFlow.assignmentSites.map((site) => (
                  <button
                    type="button"
                    key={`${site.file}:${site.line}:${site.func}`}
                    className="flow-site-row"
                    onClick={() =>
                      void revealLocation(
                        `${root.replace(/\/+$/, "")}/${site.file}`,
                        site.line,
                      )
                    }
                    title={`Open ${site.file}:${site.line}`}
                  >
                    <span className="flow-site-location">
                      {site.file}:{site.line}
                    </span>
                    <span>{site.func}</span>
                    <span className="flow-site-sources">
                      {site.sources.length > 0 ? site.sources.join(", ") : "—"}
                    </span>
                    <span>{site.callee ?? "—"}</span>
                    <span>
                      {site.matched ? (
                        <Badge tone="success">AST</Badge>
                      ) : (
                        <Badge tone="warning">runtime</Badge>
                      )}
                    </span>
                    <ArrowRightIcon size={11} className="flow-site-arrow" />
                  </button>
                ))}
              </div>
            </div>
          )}
        </>
      )}
    </div>
  );
}

function VariableFlowNode({ data, selected }: NodeProps<AppFlowNode>) {
  const item = (data as FlowNodeData).item;
  const isInput = item.role === "input";
  return (
    <div
      className={`flow-node role-${item.role}${selected ? " selected" : ""}`}
      title={`${item.label} = ${item.value}\n${item.file ?? ""}:${item.line ?? ""}`}
    >
      {isInput ? (
        <Handle type="source" position={Position.Right} className="flow-handle" />
      ) : (
        <>
          <Handle type="target" position={Position.Left} className="flow-handle" />
          <Handle type="source" position={Position.Right} className="flow-handle" />
        </>
      )}
      <div className="flow-node-head">
        <span className="flow-node-name">{item.label}</span>
        <span className="flow-node-type">{item.vtype || "value"}</span>
      </div>
      <div className="flow-node-value">{clip(item.value || "—", 54)}</div>
      <div className="flow-node-foot">
        <span>{item.func ?? "module"}</span>
        <span>{item.line ? `L${item.line}` : ""}</span>
      </div>
    </div>
  );
}

const nodeTypes = { variableNode: VariableFlowNode };
