/** Shared types mirroring the Rust data model (serde camelCase). */

export type RunStatus = "running" | "ok" | "error" | "timeout" | "cancelled" | "crashed";
export type SessionKind = "baseline" | "experiment";

export interface Project {
  id: string;
  name: string;
  rootPath: string;
  language: string;
  entryPoint: string | null;
  runArgs: string[];
  timeoutMs: number;
  tracing: boolean;
  consentGranted: boolean;
  pythonPath: string | null;
  createdAt: number;
  lastOpenedAt: number;
}

export interface ProjectConfigInput {
  entryPoint: string | null;
  runArgs: string[];
  timeoutMs: number;
  tracing: boolean;
  pythonPath: string | null;
}

export interface FileEntry {
  path: string;
  name: string;
  isDir: boolean;
  isPython: boolean;
  size: number;
}

export interface FileContent {
  path: string;
  content: string;
  size: number;
  language: string;
  modifiedAt: number;
}

export interface Session {
  id: string;
  projectId: string;
  experimentId: string | null;
  kind: SessionKind;
  label: string | null;
  command: string;
  args: string[];
  stdin: string | null;
  cwd: string;
  entryFile: string | null;
  python: string;
  status: RunStatus;
  exitCode: number | null;
  startedAt: number;
  finishedAt: number | null;
  durationMs: number | null;
  peakMemoryBytes: number | null;
  timeoutMs: number;
  error: string | null;
  stdoutPreview: string;
  stderrPreview: string;
  stdoutBytes: number;
  stderrBytes: number;
  traceEventCount: number;
  traceTruncated: boolean;
}

export interface SessionOutput {
  sessionId: string;
  stdout: string;
  stderr: string;
  stdoutTruncated: boolean;
  stderrTruncated: boolean;
}

export interface RunRequest {
  projectId: string;
  experimentId: string | null;
  baselineSessionId: string | null;
  stdin: string | null;
}

export interface TraceEvent {
  id: number;
  sessionId: string;
  seq: number;
  ts: number;
  kind: string;
  frame: number | null;
  parent: number | null;
  depth: number | null;
  file: string | null;
  line: number | null;
  func: string | null;
  name: string | null;
  value: string | null;
  vtype: string | null;
  changed: boolean | null;
}

export interface TracePage {
  events: TraceEvent[];
  total: number;
  returned: number;
}

export interface KindCount {
  kind: string;
  count: number;
}

export interface TraceStats {
  total: number;
  kinds: KindCount[];
  variables: string[];
  truncated: boolean;
}

export interface VariableSnapshot {
  name: string;
  value: string;
  vtype: string;
  file: string | null;
  line: number | null;
  func: string | null;
  seq: number;
}

export interface FlowNode {
  id: string;
  label: string;
  value: string;
  vtype: string;
  file: string | null;
  line: number | null;
  func: string | null;
  seq: number;
  ts: number;
  step: number;
  role: "target" | "input";
}

export interface FlowEdge {
  id: string;
  source: string;
  target: string;
  label: string;
  kind: "read" | "update";
}

export interface FlowAssignment {
  file: string;
  line: number;
  func: string;
  target: string;
  sources: string[];
  callee: string | null;
  kind: string;
  matched: boolean;
}

export interface DataFlow {
  variable: string;
  nodes: FlowNode[];
  edges: FlowEdge[];
  assignmentSites: FlowAssignment[];
  truncated: boolean;
  note: string;
}

export interface Experiment {
  id: string;
  projectId: string;
  baselineSessionId: string;
  name: string;
  note: string | null;
  path: string;
  createdAt: number;
  updatedAt: number;
}

export interface RunMetrics {
  durationMs: number | null;
  peakMemoryBytes: number | null;
  exitCode: number | null;
  status: RunStatus;
  traceEventCount: number;
  stdoutBytes: number;
  stderrBytes: number;
}

export interface DiffLine {
  kind: "same" | "add" | "remove";
  baselineLine: number | null;
  experimentLine: number | null;
  text: string;
}

export interface VariableDiff {
  name: string;
  baselineValue: string | null;
  baselineType: string | null;
  experimentValue: string | null;
  experimentType: string | null;
  status: "same" | "changed" | "added" | "removed";
}

export interface SessionComparison {
  baseline: Session;
  experiment: Session;
  baselineMetrics: RunMetrics;
  experimentMetrics: RunMetrics;
  stdout: DiffLine[];
  stderr: DiffLine[];
  variables: VariableDiff[];
  stdoutDivergence: number | null;
  warnings: string[];
}

export interface PythonRuntime {
  path: string;
  version: string | null;
  source: string;
  supported: boolean;
}

export interface TraceLimits {
  maxEvents: number;
  valueLength: number;
  maxDepth: number;
  maxLocals: number;
}

export interface Bootstrap {
  version: string;
  dataDir: string;
  platform: string;
  python: PythonRuntime[];
  selectedPython: string | null;
  traceLimits: TraceLimits;
  tracerPath: string;
  tracerAvailable: boolean;
  initialProjectPath: string | null;
}

export interface AnalysisSummary {
  files: number;
  assignments: number;
  errors: string[];
}

export interface ApiError {
  kind: string;
  message: string;
}

export type StreamName = "stdout" | "stderr";

export interface RunOutputEvent {
  sessionId: string;
  stream: StreamName;
  chunk: string;
}

export interface RunTraceEvent {
  sessionId: string;
  events: TraceEvent[];
  total: number;
}

export interface RunStatsEvent {
  sessionId: string;
  elapsedMs: number;
  peakMemoryBytes: number;
  traceEvents: number;
}

export interface WorkspaceChangedEvent {
  workspaceId: string;
  paths: string[];
  kind: string;
}

export type CenterTab = "editor" | "flow" | "compare" | "experiments";
export type InspectTab = "variables" | "timeline";
